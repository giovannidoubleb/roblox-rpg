-- CITY GRIND: lighting + gameplay effects, client side (spec Phase 8).
--
-- Lighting (this module OWNS the base post-processing; client/World.luau only
-- layers weather on top: its own "CityGrindWeather" ColorCorrection, Atmosphere
-- Density/Haze and Clouds. Effects never touches those, World never touches ours):
--   * "CityGrindBloom", "CityGrindSunRays", "CityGrindGrade" (ColorCorrection) and
--     Atmosphere Color/Decay, Lighting.OutdoorAmbient / ExposureCompensation /
--     GlobalShadows. Any other BloomEffect / SunRaysEffect directly under Lighting
--     (e.g. the server's default bloom) is disabled locally so they never stack.
--   * Day cycle grading from EffectsConfig.TIME_KEYS (night blue, dawn, golden
--     hour, sunset, dusk), low bloom threshold at night so Neon glows, sun rays
--     scaled by the weather, district mood (Player attribute "District") blended
--     over ~2 s, neutral inside interiors. Warm halo lights on the nearest street
--     lamps at night (pooled).
--   * Graphics setting (Player attribute "Graphics": Auto/Low/Medium/High) picks
--     EffectsConfig.LEVELS. Lighting.Technology is not scriptable, so Low instead
--     turns off GlobalShadows, bloom, sun rays and most effects.
-- Gameplay FX (all from signals the client already receives):
--   * Makes: the client watches the replicated balls cross a nearby rim -> spark
--     burst + net ripple. Dunks (BallFx "Dunk" / "SLAM!" / "POSTER!") -> big burst
--     and a short camera shake. "BIG BLOCK!" -> blue burst.
--   * Confetti: "GAME WINNER!", "YOU WIN!", "... WINS ..." callouts, RacingEvent
--     "Finished" in 1st place, Level going up, QuestsEvent "Achievement".
--   * Cash sparkle by the HUD when Cash goes up. Landing dust after a big fall.
--   * Sprint / fast driving: speed lines + a small FOV kick (Movement never
--     touches FOV; Media's photo mode and scripted cameras are left alone).
--   * Vehicles near the camera: exhaust puffs, drift smoke, pooled skid marks that
--     fade out, and a neon underglow pulse.
-- Reduced motion: camera shake, FOV kick and speed lines only on Medium/High.
-- Other modules can trigger effects with Effects.play(name, ...).

--# selene: allow(undefined_variable) -- NumberRange, NumberSequenceKeypoint, RaycastParams, UserSettings are Roblox globals

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("EffectsConfig"))
local VC = require(shared:WaitForChild("VehiclesConfig"))

local player = Players.LocalPlayer

local Effects = {}

local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"

---------------------------------------------------------------------------
-- Graphics level
---------------------------------------------------------------------------
local levelName = "Medium"
local L: Cfg.Level = Cfg.LEVELS.Medium
local levelListeners: { () -> () } = {}

local function resolveLevel(): string
	local g = player:GetAttribute("Graphics")
	if g == "Low" or g == "Medium" or g == "High" then
		return g
	end
	-- Auto: Roblox's own quality slider (1-10); Automatic counts as Medium.
	local ok, q = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
	end)
	if ok and type(q) == "number" and q > 0 then
		return if q <= 3 then "Low" elseif q <= 7 then "Medium" else "High"
	end
	return "Medium"
end

local function refreshLevel()
	local name = resolveLevel()
	if name == levelName then
		return
	end
	levelName = name
	L = Cfg.LEVELS[name] or Cfg.LEVELS.Medium
	for _, fn in levelListeners do
		task.spawn(fn)
	end
end

-- "Low" | "Medium" | "High" (Auto already resolved).
function Effects.level(): string
	return levelName
end

---------------------------------------------------------------------------
-- Post-processing + day cycle + district mood
---------------------------------------------------------------------------
local bloom: BloomEffect
local sunRays: SunRaysEffect
local grade: ColorCorrectionEffect
local atmosphere: Atmosphere? = nil

local function lerp(a: number, b: number, k: number): number
	return a + (b - a) * k
end

local function mul(a: Color3, b: Color3): Color3
	return Color3.new(a.R * b.R, a.G * b.G, a.B * b.B)
end

-- Look at a ClockTime, blended between the two surrounding keys.
local function sampleTime(t: number): Cfg.TimeKey
	local keys = Cfg.TIME_KEYS
	local a, b = keys[1], keys[#keys]
	for i = 1, #keys - 1 do
		if t >= keys[i].t and t <= keys[i + 1].t then
			a, b = keys[i], keys[i + 1]
			break
		end
	end
	local span = b.t - a.t
	local k = if span > 0 then math.clamp((t - a.t) / span, 0, 1) else 0
	k = k * k * (3 - 2 * k) -- smoothstep
	return {
		t = t,
		tint = a.tint:Lerp(b.tint, k),
		bright = lerp(a.bright, b.bright, k),
		sat = lerp(a.sat, b.sat, k),
		contrast = lerp(a.contrast, b.contrast, k),
		bloom = lerp(a.bloom, b.bloom, k),
		threshold = lerp(a.threshold, b.threshold, k),
		sun = lerp(a.sun, b.sun, k),
		ambient = a.ambient:Lerp(b.ambient, k),
		atmo = a.atmo:Lerp(b.atmo, k),
		decay = a.decay:Lerp(b.decay, k),
		exposure = lerp(a.exposure, b.exposure, k),
	}
end

-- 0 by day, 1 at night, smooth ramps at dawn and dusk.
local function nightness(t: number): number
	if t >= 7 and t <= 17.6 then
		return 0
	elseif t > 17.6 and t < 19.4 then
		return (t - 17.6) / 1.8
	elseif t > 5 and t < 7 then
		return 1 - (t - 5) / 2
	end
	return 1
end

local function isNight(): boolean
	local t = Lighting.ClockTime
	return t < 6.3 or t > 17.7
end

-- the blended mood (lerps toward the current district's)
local mood = table.clone(Cfg.NEUTRAL)
local sunWeather = 1

local function blendMood(target: Cfg.Mood, k: number)
	mood.tint = mood.tint:Lerp(target.tint, k)
	mood.nightTint = mood.nightTint:Lerp(target.nightTint, k)
	mood.sat = lerp(mood.sat, target.sat, k)
	mood.nightSat = lerp(mood.nightSat, target.nightSat, k)
	mood.contrast = lerp(mood.contrast, target.contrast, k)
	mood.bright = lerp(mood.bright, target.bright, k)
	mood.nightBright = lerp(mood.nightBright, target.nightBright, k)
	mood.bloom = lerp(mood.bloom, target.bloom, k)
	mood.nightBloom = lerp(mood.nightBloom, target.nightBloom, k)
end

local function indoors(): boolean
	local interior = player:GetAttribute("Interior")
	return type(interior) == "string" and interior ~= ""
end

local function updateLighting(dt: number)
	local t = Lighting.ClockTime
	local tod = sampleTime(t)
	local n = nightness(t)
	local inside = indoors()

	local district = player:GetAttribute("District")
	local target = if inside then Cfg.NEUTRAL else (Cfg.MOODS[district or ""] or Cfg.NEUTRAL)
	blendMood(target, math.clamp(dt / 2, 0, 1))
	local weather = Workspace:GetAttribute("Weather")
	local wantSun = if inside then 0 else (Cfg.WEATHER_SUN[if type(weather) == "string" then weather else "Clear"] or 1)
	sunWeather = lerp(sunWeather, wantSun, math.clamp(dt / 4, 0, 1))

	-- interiors keep only a hint of the outdoor time-of-day grade
	local w = if inside then 0.25 else 1
	grade.TintColor = mul(Color3.new(1, 1, 1):Lerp(tod.tint, w), mood.tint:Lerp(mood.nightTint, n))
	grade.Brightness = tod.bright * w + lerp(mood.bright, mood.nightBright, n)
	grade.Saturation = tod.sat * w + lerp(mood.sat, mood.nightSat, n)
	grade.Contrast = tod.contrast * w + mood.contrast

	bloom.Enabled = L.bloom
	bloom.Intensity = math.max(0, lerp(0.5, tod.bloom, w) + lerp(mood.bloom, mood.nightBloom, n))
	bloom.Threshold = lerp(1.4, tod.threshold, w)
	local sun = tod.sun * sunWeather
	sunRays.Enabled = L.sunRays and sun > 0.01
	sunRays.Intensity = sun

	Lighting.OutdoorAmbient = tod.ambient
	Lighting.ExposureCompensation = tod.exposure
	if Lighting.GlobalShadows ~= L.shadows then
		Lighting.GlobalShadows = L.shadows
	end
	local a = atmosphere
	if a and a.Parent then
		-- Density / Haze belong to the weather (client/World.luau)
		a.Color = tod.atmo
		a.Decay = tod.decay
	end
end

local function setupPost()
	local function silence(child: Instance)
		if (child:IsA("BloomEffect") or child:IsA("SunRaysEffect")) and not child.Name:match("^CityGrind") then
			(child :: any).Enabled = false
		end
	end
	for _, c in Lighting:GetChildren() do
		silence(c)
	end
	Lighting.ChildAdded:Connect(silence)

	bloom = Instance.new("BloomEffect")
	bloom.Name = "CityGrindBloom"
	bloom.Size = 28
	bloom.Intensity = 0.5
	bloom.Threshold = 1.6
	bloom.Parent = Lighting
	sunRays = Instance.new("SunRaysEffect")
	sunRays.Name = "CityGrindSunRays"
	sunRays.Spread = 0.55
	sunRays.Intensity = 0.1
	sunRays.Parent = Lighting
	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "CityGrindGrade"
	grade.Parent = Lighting

	task.spawn(function()
		local a = Lighting:FindFirstChildOfClass("Atmosphere") or Lighting:WaitForChild("Atmosphere", 8)
		if not (a and a:IsA("Atmosphere")) then
			-- the City was placed by hand without one: a local default
			local made = Instance.new("Atmosphere")
			made.Density = 0.3
			made.Haze = 1.2
			made.Parent = Lighting
			a = made
		end
		atmosphere = a :: Atmosphere
	end)

	task.spawn(function()
		local last = os.clock()
		local levelAt = 0
		while true do
			task.wait(0.1)
			local now = os.clock()
			if now - levelAt > 3 then
				levelAt = now
				refreshLevel() -- Auto follows Roblox's quality slider
			end
			local ok, err = pcall(updateLighting, now - last)
			if not ok then
				warn("[CityGrind] Effects lighting:", err)
				task.wait(5)
			end
			last = now
		end
	end)
end

---------------------------------------------------------------------------
-- Street lamp halos (night, pooled, nearest few only)
---------------------------------------------------------------------------
local lampHeads: { BasePart } = {}
local halos: { PointLight } = {}

local function scanLamps()
	table.clear(lampHeads)
	local city = Workspace:FindFirstChild("City")
	if not city then
		return
	end
	for _, d in city:GetDescendants() do
		if d.Name == "StreetLamp" and d:IsA("Model") then
			local head = d:FindFirstChild("Head")
			if head and head:IsA("BasePart") then
				table.insert(lampHeads, head)
			end
		end
	end
end

local function updateHalos()
	local want = if isNight() and not indoors() then L.lampHalos else 0
	local camera = Workspace.CurrentCamera
	local chosen: { BasePart } = {}
	if want > 0 and camera then
		local camPos = camera.CFrame.Position
		local scored = {}
		for _, head in lampHeads do
			if head.Parent then
				local d = (head.Position - camPos).Magnitude
				if d < 160 then
					table.insert(scored, { head = head, d = d })
				end
			end
		end
		table.sort(scored, function(x, y)
			return x.d < y.d
		end)
		for i = 1, math.min(want, #scored) do
			chosen[i] = scored[i].head
		end
	end
	for i = 1, math.max(#chosen, #halos) do
		local head = chosen[i]
		local halo = halos[i]
		if head then
			local current = halo
			if not current or (current.Parent ~= head and not pcall(function()
				current.Parent = head
			end)) then
				-- new, or destroyed along with a lamp that went away
				local made = Instance.new("PointLight")
				made.Name = "CityGrindHalo"
				made.Range = 18
				made.Brightness = 0.9
				made.Shadows = false
				made.Color = Color3.fromRGB(255, 205, 140)
				made.Parent = head
				halos[i] = made
			end
		elseif halo then
			pcall(function()
				halo.Parent = nil
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Particle pool: one emitter per effect, moved and :Emit()'d (particles stay
-- where they were emitted, so one emitter serves every position).
---------------------------------------------------------------------------
type Fx = { att: Attachment, em: ParticleEmitter }
local fx: { [string]: Fx } = {}

local function emitter(name: string, props: { [string]: any }): Fx
	local att = Instance.new("Attachment")
	att.Name = "CityGrindFx_" .. name
	att.Parent = Workspace.Terrain
	local em = Instance.new("ParticleEmitter")
	em.Enabled = false
	em.Rate = 0
	local texture = props.Texture
	props.Texture = nil
	local target: any = em
	for k, v in props do
		target[k] = v
	end
	if texture then
		pcall(function()
			em.Texture = texture -- a missing built-in texture just shows the default
		end)
	end
	em.Parent = att
	local f = { att = att, em = em }
	fx[name] = f
	return f
end

local function burst(name: string, at: CFrame | Vector3, count: number)
	local f = fx[name]
	if not f then
		return
	end
	local n = math.floor(count * L.particles + 0.5)
	if n <= 0 then
		return
	end
	f.att.WorldCFrame = if typeof(at) == "Vector3" then CFrame.new(at) else at
	f.em:Emit(n)
end

local CONFETTI_COLORS = { Color3.fromRGB(255, 70, 90), Color3.fromRGB(255, 210, 60), Color3.fromRGB(70, 200, 255), Color3.fromRGB(120, 255, 130) }

local function buildEmitters()
	emitter("Sparks", {
		Texture = TEX_SPARK,
		Color = ColorSequence.new(Color3.fromRGB(255, 230, 120), Color3.fromRGB(255, 140, 40)),
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(0.35, 0.8),
		Speed = NumberRange.new(14, 28),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -35, 0),
		Drag = 3,
	})
	emitter("BlueSparks", {
		Texture = TEX_SPARK,
		Color = ColorSequence.new(Color3.fromRGB(170, 230, 255), Color3.fromRGB(60, 120, 255)),
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(0.3, 0.7),
		Speed = NumberRange.new(18, 32),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -20, 0),
		Drag = 4,
	})
	emitter("DunkRing", {
		Texture = TEX_SPARK,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 120, 30)),
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0) }),
		Lifetime = NumberRange.new(0.5, 1.0),
		Speed = NumberRange.new(30, 50),
		SpreadAngle = Vector2.new(180, 25), -- flat ring around the rim
		Acceleration = Vector3.new(0, -25, 0),
		Drag = 3,
	})
	for i, color in CONFETTI_COLORS do
		emitter("Confetti" .. i, {
			Color = ColorSequence.new(color),
			LightEmission = 0.3,
			Size = NumberSequence.new(0.32),
			Squash = NumberSequence.new(0.6),
			Lifetime = NumberRange.new(2.4, 3.6),
			Speed = NumberRange.new(26, 42),
			SpreadAngle = Vector2.new(40, 40),
			Acceleration = Vector3.new(0, -16, 0),
			Drag = 1.4,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-320, 320),
		})
	end
	emitter("Dust", {
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Color3.fromRGB(205, 195, 175)),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3.6) }),
		Lifetime = NumberRange.new(0.7, 1.3),
		Speed = NumberRange.new(7, 12),
		SpreadAngle = Vector2.new(85, 85), -- mostly sideways from an upward-facing attachment
		Acceleration = Vector3.new(0, 1.5, 0),
		Drag = 4,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
	})
	emitter("Exhaust", {
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Color3.fromRGB(150, 150, 155)),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) }),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 2.2) }),
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(3, 5),
		SpreadAngle = Vector2.new(15, 15),
		Acceleration = Vector3.new(0, 2, 0),
		Drag = 2,
		LightInfluence = 1,
		EmissionDirection = Enum.NormalId.Back,
	})
	emitter("TireSmoke", {
		Texture = TEX_SMOKE,
		Color = ColorSequence.new(Color3.fromRGB(225, 225, 228)),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) }),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 6.5) }),
		Lifetime = NumberRange.new(1.1, 1.9),
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = Vector3.new(0, 2.5, 0),
		Drag = 2,
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
	})
end

local function confetti(pos: Vector3, scale: number?)
	local each = Cfg.CONFETTI * (scale or 1) / #CONFETTI_COLORS
	for i = 1, #CONFETTI_COLORS do
		burst("Confetti" .. i, pos, each)
	end
end

local function characterRoot(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function confettiOnMe(scale: number?)
	local root = characterRoot()
	if root then
		confetti(root.Position + Vector3.new(0, 7, 0), scale)
	end
end

---------------------------------------------------------------------------
-- Camera shake (undo before the camera scripts run, re-apply after them, so
-- the offset never leaks into the player's look direction)
---------------------------------------------------------------------------
local shakeMag, shakeDur, shakeUntil = 0, 0, 0
local shakeOffset = CFrame.identity
local shakeBound = false

local function stopShake()
	if shakeBound then
		shakeBound = false
		RunService:UnbindFromRenderStep("CityGrindShakeUndo")
		RunService:UnbindFromRenderStep("CityGrindShake")
	end
end

local function shake(magnitude: number, duration: number)
	if not L.motion then
		return
	end
	local now = os.clock()
	if now < shakeUntil and magnitude * duration < shakeMag * (shakeUntil - now) then
		return -- a stronger shake is already running
	end
	shakeMag, shakeDur, shakeUntil = magnitude, duration, now + duration
	if shakeBound then
		return
	end
	shakeBound = true
	RunService:BindToRenderStep("CityGrindShakeUndo", Enum.RenderPriority.Camera.Value - 1, function()
		local camera = Workspace.CurrentCamera
		if camera and shakeOffset ~= CFrame.identity then
			camera.CFrame *= shakeOffset:Inverse()
		end
		shakeOffset = CFrame.identity
	end)
	RunService:BindToRenderStep("CityGrindShake", Enum.RenderPriority.Camera.Value + 1, function()
		local t = os.clock()
		local camera = Workspace.CurrentCamera
		if t >= shakeUntil or not L.motion then
			stopShake()
			return
		end
		if not camera or camera.CameraType ~= Enum.CameraType.Custom then
			return
		end
		local m = shakeMag * ((shakeUntil - t) / shakeDur)
		local f = t * 28
		shakeOffset = CFrame.new(math.noise(f, 0.3) * m * 0.35, math.noise(f, 1.7) * m * 0.35, 0)
			* CFrame.Angles(math.noise(f, 3.1) * m * 0.02, math.noise(f, 4.9) * m * 0.02, math.noise(f, 6.3) * m * 0.012)
		camera.CFrame *= shakeOffset
	end)
end

---------------------------------------------------------------------------
-- Screen effects: cash sparkle, speed lines
---------------------------------------------------------------------------
local screen: ScreenGui
local speedHolder: Frame
type Line = { frame: Frame, angle: number, r: number, speed: number }
local lines: { Line } = {}

local function buildScreen()
	screen = Instance.new("ScreenGui")
	screen.Name = "CityGrindEffects"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false -- same space as the HUD
	screen.DisplayOrder = 1
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = player:WaitForChild("PlayerGui")

	speedHolder = Instance.new("Frame")
	speedHolder.Name = "SpeedLines"
	speedHolder.BackgroundTransparency = 1
	speedHolder.Size = UDim2.fromScale(1, 1)
	speedHolder.Visible = false
	speedHolder.Parent = screen
	for _ = 1, 18 do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BackgroundTransparency = 1
		f.Parent = speedHolder
		table.insert(lines, { frame = f, angle = math.random() * math.pi * 2, r = 0.35 + math.random() * 0.6, speed = 0.9 + math.random() * 0.8 })
	end
end

local function cashSparkle(amount: number)
	if not screen then
		return
	end
	-- the HUD card is top-right; its cash text starts ~210 px from the right edge
	local origin = UDim2.new(1, -190, 0, 26)
	local count = math.floor((if amount >= 1000 then 12 elseif amount >= 100 then 8 else 5) * math.max(L.particles, 0.5) + 0.5)
	for i = 1, count do
		local star = Instance.new("TextLabel")
		star.BackgroundTransparency = 1
		star.Text = if i % 3 == 0 then "$" else "✦"
		star.Font = Enum.Font.GothamBlack
		star.TextSize = 12 + math.random(0, 10)
		star.TextColor3 = if i % 2 == 0 then Color3.fromRGB(255, 225, 90) else Color3.fromRGB(120, 255, 150)
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Size = UDim2.fromOffset(24, 24)
		star.Position = origin
		star.Rotation = math.random(-30, 30)
		star.Parent = screen
		local a = (i / count) * math.pi * 2 + math.random() * 0.5
		local dist = 28 + math.random() * 34
		local goal = origin + UDim2.fromOffset(math.cos(a) * dist, math.sin(a) * dist * 0.7)
		TweenService:Create(star, TweenInfo.new(0.7 + math.random() * 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = goal,
			TextTransparency = 1,
			Rotation = star.Rotation + math.random(-90, 90),
		}):Play()
		task.delay(1.1, star.Destroy, star)
	end
end

---------------------------------------------------------------------------
-- Basketball: make detection, net ripple, dunks, blocks
---------------------------------------------------------------------------
type Hoop = { model: Model, rim: Vector3, radius: number, net: { BasePart } }
local nearHoops: { Hoop } = {}
local hoopByModel: { [Model]: Hoop } = {}
local ballLast: { [BasePart]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any
local ballDebounce: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local rippleBase: { [BasePart]: CFrame } = {} -- rest pose of strands mid-ripple
local rippleOwner: { [BasePart]: {} } = {}
local dunkHint = 0
local lastMake: { hoop: Hoop, t: number, big: boolean }? = nil

local function refreshHoops()
	table.clear(nearHoops)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	for _, court in CollectionService:GetTagged("Court") do
		if court:IsA("Model") then
			local center = court:GetAttribute("CourtCenter")
			local c = if typeof(center) == "Vector3" then center else court:GetPivot().Position
			if (c - camPos).Magnitude < Cfg.HOOP_RANGE + 60 then
				for _, side in { "North", "South" } do
					local hm = court:FindFirstChild("Hoop" .. side)
					local marker = hm and hm:FindFirstChild("RimCenter", true)
					if hm and hm:IsA("Model") and marker and marker:IsA("Attachment") then
						local hoop = hoopByModel[hm]
						if not hoop then
							local net = {}
							for _, d in hm:GetChildren() do
								if d.Name == "Net" and d:IsA("BasePart") then
									table.insert(net, d)
								end
							end
							local radius = hm:GetAttribute("RimRadius")
							hoop = { model = hm, rim = marker.WorldPosition, radius = if type(radius) == "number" then radius else 1.45, net = net }
							hoopByModel[hm] = hoop
						end
						table.insert(nearHoops, hoop)
					end
				end
			end
		end
	end
end

-- Swing the net strands around their top ends for a moment (local only).
local function rippleNet(hoop: Hoop, strength: number)
	if not L.netRipple or #hoop.net == 0 then
		return
	end
	local start = os.clock()
	local token = {}
	local strands = {}
	for i, strand in hoop.net do
		if strand.Parent then
			local base = rippleBase[strand] or strand.CFrame
			rippleBase[strand] = base
			rippleOwner[strand] = token
			table.insert(strands, { part = strand, base = base, half = strand.Size.Z / 2, phase = i * 0.8 })
		end
	end
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - start
		local done = t > 0.8
		local decay = math.max(0, 1 - t / 0.8)
		for _, s in strands do
			if rippleOwner[s.part] ~= token then
				continue -- a newer ripple owns this strand
			end
			if done then
				s.part.CFrame = s.base
				rippleBase[s.part] = nil
				rippleOwner[s.part] = nil
			else
				local a = math.sin(t * 26 + s.phase) * 0.45 * strength * decay
				local b = math.cos(t * 19 + s.phase) * 0.2 * strength * decay
				s.part.CFrame = s.base * CFrame.new(0, 0, s.half) * CFrame.Angles(a, b, 0) * CFrame.new(0, 0, -s.half)
			end
		end
		if done then
			conn:Disconnect()
		end
	end)
end

local function bigDunk(hoop: Hoop)
	burst("DunkRing", CFrame.new(hoop.rim), Cfg.DUNK_SPARKS)
	burst("Sparks", hoop.rim, Cfg.DUNK_SPARKS * 0.5)
	rippleNet(hoop, 1.6)
	local root = characterRoot()
	if root and (root.Position - hoop.rim).Magnitude < 45 then
		shake(1.2, 0.4)
	end
end

local function onMake(hoop: Hoop)
	local now = os.clock()
	if now - dunkHint < 2.5 then
		dunkHint = 0
		lastMake = { hoop = hoop, t = now, big = true }
		bigDunk(hoop)
		return
	end
	lastMake = { hoop = hoop, t = now, big = false }
	burst("Sparks", hoop.rim - Vector3.new(0, 0.8, 0), Cfg.MAKE_SPARKS)
	rippleNet(hoop, 1)
end

-- "SLAM!" / "POSTER!" can arrive before or after the ball is seen in the net.
local function dunkCallout()
	local now = os.clock()
	local m = lastMake
	if m and now - m.t < 1.5 then
		if not m.big then
			m.big = true
			bigDunk(m.hoop)
		end
	else
		dunkHint = now
	end
end

local function checkBalls()
	if #nearHoops == 0 then
		return
	end
	local folder = Workspace:FindFirstChild("Basketballs")
	if not folder then
		return
	end
	local now = os.clock()
	for _, ball in folder:GetChildren() do
		if not ball:IsA("BasePart") then
			continue
		end
		local pos = ball.Position
		local prev = ballLast[ball]
		ballLast[ball] = pos
		if prev and now > (ballDebounce[ball] or 0) and (pos - prev).Magnitude < 15 then
			for _, hoop in nearHoops do
				local rim = hoop.rim
				if prev.Y >= rim.Y and pos.Y < rim.Y then
					local mid = (prev + pos) / 2
					local flat = Vector3.new(mid.X - rim.X, 0, mid.Z - rim.Z)
					if flat.Magnitude < hoop.radius then
						ballDebounce[ball] = now + 1
						onMake(hoop)
						break
					end
				end
			end
		end
	end
end

local function onCallout(text: string)
	local upper = text:upper()
	if upper == "GAME WINNER!" or upper == "YOU WIN!" or upper:find(" WINS ", 1, true) then
		confettiOnMe(if upper == "GAME WINNER!" then 1.3 else 1)
	elseif upper == "SLAM!" or upper == "POSTER!" then
		dunkCallout()
	elseif upper == "BIG BLOCK!" then
		local root = characterRoot()
		local folder = Workspace:FindFirstChild("Basketballs")
		if root and folder then
			local best, bestD = nil, 40
			for _, ball in folder:GetChildren() do
				if ball:IsA("BasePart") then
					local d = (ball.Position - root.Position).Magnitude
					if d < bestD then
						best, bestD = ball, d
					end
				end
			end
			if best then
				burst("BlueSparks", best.Position, 34)
				if bestD < 20 then
					shake(0.6, 0.25)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Vehicles: exhaust, drift smoke, skid marks, underglow pulse
---------------------------------------------------------------------------
type Car = {
	model: Model,
	chassis: BasePart,
	spec: VC.Spec,
	seat: VehicleSeat?,
	rear: { BasePart },
	prev: { [BasePart]: Vector3 },
	glowPart: BasePart?,
	glowLight: PointLight?,
	pulsing: boolean,
	exhaustAt: number,
	smokeAt: number,
	params: RaycastParams,
	phase: number,
}
local cars: { [Model]: Car } = {}

local function trackCar(model: Instance)
	if not model:IsA("Model") or cars[model] then
		return
	end
	task.spawn(function()
		local chassis = model:WaitForChild("Chassis", 15)
		local spec = VC.byId[model:GetAttribute("VehicleId") or ""]
		if not chassis or not chassis:IsA("BasePart") or not spec or not model.Parent then
			return
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.RespectCanCollide = true
		params.FilterDescendantsInstances = { model }
		local car: Car = {
			model = model,
			chassis = chassis,
			spec = spec,
			seat = model:FindFirstChild("DriverSeat") :: VehicleSeat?,
			rear = {},
			prev = {},
			pulsing = false,
			exhaustAt = 0,
			smokeAt = 0,
			params = params,
			phase = math.random() * 6,
		}
		for _, d in model:GetDescendants() do
			if d:IsA("Motor6D") and d.Name == "WheelMotor" and d:GetAttribute("Steer") ~= true and d.Part1 then
				table.insert(car.rear, d.Part1)
			elseif d:IsA("BasePart") and d.Name == "Underglow" then
				car.glowPart = d
				car.glowLight = d:FindFirstChildOfClass("PointLight")
			end
		end
		cars[model] = car
	end)
end

-- Skid marks: a ring buffer of thin dark parts that fade out and get reused.
type Skid = { part: BasePart, born: number }
local skids: { Skid } = {}
local skidNext = 1
local skidFolder: Folder

local function trimSkids()
	local cap = L.skidMarks
	while #skids > cap do
		local s = table.remove(skids) :: Skid
		s.part:Destroy()
	end
	if skidNext > math.max(cap, 1) then
		skidNext = 1
	end
end

local function placeSkid(a: Vector3, b: Vector3, normal: Vector3, width: number)
	local cap = L.skidMarks
	if cap <= 0 then
		return
	end
	local s = skids[skidNext]
	if not s then
		local p = Instance.new("Part")
		p.Name = "Skid"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.fromRGB(22, 22, 24)
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = skidFolder
		s = { part = p, born = 0 }
		skids[skidNext] = s
	end
	local len = (b - a).Magnitude
	s.part.Size = Vector3.new(width, 0.05, len + 0.15)
	s.part.CFrame = CFrame.lookAt((a + b) / 2, b, normal)
	s.part.Transparency = 0.3
	s.born = os.clock()
	skidNext = skidNext % cap + 1
end

local function fadeSkids()
	local now = os.clock()
	for _, s in skids do
		if s.part.Transparency < 1 then
			local k = (now - s.born) / Cfg.SKID_LIFETIME
			s.part.Transparency = if k >= 1 then 1 else 0.3 + 0.7 * k * k
		end
	end
end

local function updateCars(camPos: Vector3)
	local now = os.clock()
	for model, car in cars do
		local chassis = car.chassis
		if not chassis.Parent or not model.Parent then
			if car.glowLight then
				car.glowLight.Brightness = 2.5
			end
			cars[model] = nil
			continue
		end
		if (chassis.Position - camPos).Magnitude > Cfg.VEHICLE_FX_RANGE then
			table.clear(car.prev)
			continue
		end
		local spec = car.spec
		local cf = chassis.CFrame
		local vel = chassis.AssemblyLinearVelocity
		local speed = vel.Magnitude
		local seat = car.seat
		local running = seat ~= nil and seat.Occupant ~= nil

		-- exhaust puffs (engines only), faster when on the throttle
		if L.exhaust and running and (spec.kind == "Car" or spec.kind == "Motorcycle") then
			local throttle = if seat then math.abs(seat.ThrottleFloat) else 0
			if now >= car.exhaustAt then
				car.exhaustAt = now + (if throttle > 0.1 then 0.07 else 0.22)
				local size = chassis.Size
				local x = if spec.twoWheel then 0.3 else size.X * 0.3
				local at = cf * CFrame.new(x, -size.Y / 2 + 0.35, size.Z / 2 + 0.2)
				burst("Exhaust", at, if throttle > 0.1 then 2 else 1)
			end
		end

		-- drift: sideways slip at speed -> tyre smoke + skid marks under the rear wheels
		local slip = math.abs(vel:Dot(cf.RightVector))
		local drifting = running and speed > Cfg.DRIFT_MIN_SPEED and slip > Cfg.DRIFT_SLIP
		if drifting then
			local emitSmoke = now >= car.smokeAt
			if emitSmoke then
				car.smokeAt = now + 0.06
			end
			for _, wheel in car.rear do
				local hit = Workspace:Raycast(wheel.Position, Vector3.new(0, -(spec.wheelRadius + 2), 0), car.params)
				if hit then
					local p = hit.Position + hit.Normal * 0.03
					if emitSmoke then
						burst("TireSmoke", p + Vector3.new(0, 0.5, 0), math.clamp(slip / 10, 1, 3))
					end
					local last = car.prev[wheel]
					if not last or (p - last).Magnitude > 6 then
						car.prev[wheel] = p
					elseif (p - last).Magnitude > 0.9 then
						placeSkid(last, p, hit.Normal, math.max(0.3, spec.wheelWidth * 0.9))
						car.prev[wheel] = p
					end
				else
					car.prev[wheel] = nil
				end
			end
		elseif next(car.prev) then
			table.clear(car.prev)
		end

		-- neon underglow pulse (only when the owner fitted a glow)
		local light = car.glowLight
		local glowOn = car.glowPart ~= nil and (car.glowPart :: BasePart).Transparency < 1 and light ~= nil and light.Enabled
		if light and glowOn and L.underglowPulse then
			car.pulsing = true
			light.Brightness = 2.5 * (0.7 + 0.3 * math.sin(now * 3 + car.phase))
		elseif light and car.pulsing then
			car.pulsing = false
			light.Brightness = 2.5
		end
	end
end

---------------------------------------------------------------------------
-- Player movement: landing dust, sprint / speed FOV kick and speed lines
---------------------------------------------------------------------------
local humanoid: Humanoid? = nil
local fallSpeed = 0
local fovKick = 0
local fovApplied = 0
local fovWritten: number? = nil
local lineK = 0

local function lazyModule(name: string): any
	local m = script.Parent:FindFirstChild(name)
	if not m then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok then mod else nil
end
local Movement: any = nil
local Media: any = nil

local function onCharacter(character: Model)
	local hum = character:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	humanoid = hum
	fallSpeed = 0
	hum.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Landed then
			local speed = fallSpeed
			fallSpeed = 0
			local root = characterRoot()
			if root and speed > Cfg.LANDING_MIN_FALL then
				local feet = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2, 0)
				burst("Dust", feet, math.clamp((speed - 30) / 4, 3, 22))
				if speed > 110 then
					shake(0.5, 0.25)
				end
			end
		end
	end)
end

-- 0..1 how fast the local player is going (sprint or vehicle), and whether driving.
local function speedFactor(): (number, number)
	local hum = humanoid
	if not hum or hum.Health <= 0 then
		return 0, 0
	end
	local seat = hum.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		local model = seat:FindFirstAncestorOfClass("Model")
		local spec = model and VC.byId[model:GetAttribute("VehicleId") or ""]
		local top = if spec then spec.topSpeed else 60
		local frac = math.clamp(seat.AssemblyLinearVelocity.Magnitude / top, 0, 1.2)
		return Cfg.DRIVE_FOV * math.clamp((frac - 0.35) / 0.65, 0, 1), math.clamp((frac - 0.55) / 0.45, 0, 1)
	end
	if Movement and Movement.isSprinting() and hum.MoveDirection.Magnitude > 0.1 then
		return Cfg.SPRINT_FOV, 0.45
	end
	return 0, 0
end

local function cameraFree(camera: Camera): boolean
	if camera.CameraType ~= Enum.CameraType.Custom then
		return false
	end
	if Media and Media.isCameraOpen and Media.isCameraOpen() then
		return false
	end
	return player:GetAttribute("StoryCinematic") ~= true
end

local function updateCameraFx(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local free = cameraFree(camera)
	local wantFov, wantLines = 0, 0
	if free and L.motion then
		wantFov, wantLines = speedFactor()
	end

	-- FOV kick: added on top of whatever FOV someone else set; if another script
	-- writes the FOV (photo zoom, cutscene) that becomes the new base.
	if not free then
		if fovApplied ~= 0 and fovWritten and math.abs(camera.FieldOfView - fovWritten) < 0.01 then
			camera.FieldOfView -= fovApplied
		end
		fovApplied, fovWritten, fovKick = 0, nil, 0
	else
		if fovWritten and math.abs(camera.FieldOfView - fovWritten) > 0.01 then
			fovApplied = 0
		end
		fovKick = lerp(fovKick, wantFov, math.clamp(dt * 5, 0, 1))
		if math.abs(fovKick) < 0.02 and fovApplied == 0 then
			fovKick = 0
		elseif math.abs(fovKick - fovApplied) > 0.005 then
			local base = camera.FieldOfView - fovApplied
			camera.FieldOfView = math.clamp(base + fovKick, 1, 120)
			fovApplied = camera.FieldOfView - base
			fovWritten = camera.FieldOfView
		end
	end

	-- speed lines
	lineK = lerp(lineK, wantLines, math.clamp(dt * 6, 0, 1))
	if lineK < 0.02 then
		if speedHolder.Visible then
			speedHolder.Visible = false
		end
		return
	end
	speedHolder.Visible = true
	for _, line in lines do
		line.r += dt * line.speed * (0.6 + lineK)
		if line.r > 1 then
			line.r = 0.35 + math.random() * 0.15
			line.angle = math.random() * math.pi * 2
			line.speed = 0.9 + math.random() * 0.8
		end
		local f = line.frame
		local edge = math.clamp((line.r - 0.35) / 0.25, 0, 1) * math.clamp((1 - line.r) / 0.2, 0, 1)
		f.Position = UDim2.fromScale(0.5 + math.cos(line.angle) * line.r * 0.62, 0.5 + math.sin(line.angle) * line.r * 0.62)
		f.Rotation = math.deg(line.angle)
		f.Size = UDim2.fromOffset(60 + 140 * lineK, 2)
		f.BackgroundTransparency = 1 - 0.5 * lineK * edge
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Effects.play(name, ...) for other client modules:
--   "Sparks"(pos), "Dunk"(pos), "Block"(pos), "Confetti"(pos?, scale?),
--   "CashSparkle"(amount?), "Dust"(pos), "Shake"(magnitude, seconds)
function Effects.play(name: string, ...: any)
	local a, b = ...
	if name == "Sparks" and typeof(a) == "Vector3" then
		burst("Sparks", a, Cfg.MAKE_SPARKS)
	elseif name == "Dunk" and typeof(a) == "Vector3" then
		burst("DunkRing", a, Cfg.DUNK_SPARKS)
		shake(1.2, 0.4)
	elseif name == "Block" and typeof(a) == "Vector3" then
		burst("BlueSparks", a, 34)
	elseif name == "Confetti" then
		if typeof(a) == "Vector3" then
			confetti(a, if type(b) == "number" then b else nil)
		else
			confettiOnMe(if type(a) == "number" then a else nil)
		end
	elseif name == "CashSparkle" then
		cashSparkle(if type(a) == "number" then a else 100)
	elseif name == "Dust" and typeof(a) == "Vector3" then
		burst("Dust", a, 12)
	elseif name == "Shake" and type(a) == "number" then
		shake(a, if type(b) == "number" then b else 0.3)
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Effects.start()
	levelName = ""
	refreshLevel()
	player:GetAttributeChangedSignal("Graphics"):Connect(refreshLevel)

	setupPost()
	buildEmitters()
	skidFolder = Instance.new("Folder")
	skidFolder.Name = "CityGrindSkids"
	skidFolder.Parent = Workspace
	table.insert(levelListeners, trimSkids)
	table.insert(levelListeners, updateHalos)

	task.spawn(function()
		buildScreen()
		Movement = lazyModule("Movement")
		Media = lazyModule("Media")

		-- cash sparkle + level-up confetti (only real changes after the save loaded)
		local shownCash: number? = nil
		local shownLevel: number? = nil
		local function snapshot()
			if player:GetAttribute("DataLoaded") then
				shownCash = player:GetAttribute("Cash")
				shownLevel = player:GetAttribute("Level")
			end
		end
		snapshot()
		player:GetAttributeChangedSignal("DataLoaded"):Connect(snapshot)
		player:GetAttributeChangedSignal("Cash"):Connect(function()
			local cash = player:GetAttribute("Cash")
			if type(cash) ~= "number" or not player:GetAttribute("DataLoaded") then
				return
			end
			if type(shownCash) == "number" and cash > shownCash then
				cashSparkle(cash - shownCash)
			end
			shownCash = cash
		end)
		player:GetAttributeChangedSignal("Level"):Connect(function()
			local lv = player:GetAttribute("Level")
			if type(lv) ~= "number" or not player:GetAttribute("DataLoaded") then
				return
			end
			if type(shownLevel) == "number" and lv > shownLevel then
				confettiOnMe(1.2)
			end
			shownLevel = lv
		end)
	end)

	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)

	for _, m in CollectionService:GetTagged("CityVehicle") do
		trackCar(m)
	end
	CollectionService:GetInstanceAddedSignal("CityVehicle"):Connect(trackCar)
	CollectionService:GetInstanceRemovedSignal("CityVehicle"):Connect(function(m)
		cars[m :: any] = nil
	end)

	-- replicated signals: basketball callouts / dunks, races, achievements
	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		local ballFx = remotes:WaitForChild("BallFx", 30)
		if ballFx and ballFx:IsA("RemoteEvent") then
			ballFx.OnClientEvent:Connect(function(kind: any, arg: any)
				if kind == "Callout" and type(arg) == "string" then
					onCallout(arg)
				elseif kind == "Dunk" then
					dunkHint = os.clock() -- the jump starts now; the make follows
				end
			end)
		end
	end)
	task.spawn(function()
		local racing = shared:WaitForChild("Remotes"):WaitForChild("RacingEvent", 60)
		if racing and racing:IsA("RemoteEvent") then
			racing.OnClientEvent:Connect(function(kind: any, data: any)
				if kind == "Finished" and type(data) == "table" and data.place == 1 and (tonumber(data.total) or 1) > 1 then
					confettiOnMe(1.4)
				end
			end)
		end
	end)
	task.spawn(function()
		local quests = shared:WaitForChild("Remotes"):WaitForChild("QuestsEvent", 60)
		if quests and quests:IsA("RemoteEvent") then
			quests.OnClientEvent:Connect(function(kind: any)
				if kind == "Achievement" then
					confettiOnMe(0.7)
				end
			end)
		end
	end)

	-- per-frame work: only nearby balls/hoops and vehicles, never the whole map
	RunService.Heartbeat:Connect(function()
		local hum = humanoid
		if hum and hum:GetState() == Enum.HumanoidStateType.Freefall then
			local root = characterRoot()
			if root then
				fallSpeed = math.max(fallSpeed, -root.AssemblyLinearVelocity.Y)
			end
		end
		checkBalls()
		local camera = Workspace.CurrentCamera
		if camera then
			updateCars(camera.CFrame.Position)
		end
	end)
	RunService.RenderStepped:Connect(function(dt)
		if speedHolder then
			updateCameraFx(dt)
		end
	end)

	-- slow housekeeping
	task.spawn(function()
		task.wait(3)
		scanLamps()
		local tick = 0
		while true do
			task.wait(0.5)
			tick += 1
			refreshHoops()
			fadeSkids()
			if tick % 3 == 0 then
				updateHalos()
			end
			if tick % 120 == 0 then
				scanLamps() -- districts / hand-placed lamps that streamed in later
			end
		end
	end)
end

return Effects
