-- CITY GRIND: the living world, client side (spec 65, 66, 81, 82, 89).
--   * Collectibles: spins and bobs nearby items, hides the ones this player
--     already owns (local only), asks the server to pick one up when you walk
--     into it (the server re-checks the distance), and the "Collection" phone
--     app (progress per set, hints by district, secrets found, weather).
--   * Weather: renders the server's Workspace attribute "Weather" with local
--     Atmosphere / Clouds / ColorCorrection tweaks (never touches ClockTime, so
--     the day/night cycle keeps working; the base post-processing — bloom, sun
--     rays, day/district grading, Atmosphere Color/Decay — is owned by
--     client/Effects.luau, this layers weather on top), a rain emitter that follows the camera
--     (off under roofs and indoors) and lightning flashes in storms. Rain density
--     follows the Graphics setting (or Roblox's quality slider on Auto). A small chip shows the weather.
--   * Pedestrians: procedural leg/arm swing for nearby "CityNPC" rigs.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local WC = require(shared:WaitForChild("WorldConfig"))
local DC = require(shared:WaitForChild("DistrictsConfig"))
local remotes = shared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local colors = UI.colors

local World = {}

---------------------------------------------------------------------------
-- Collectibles
---------------------------------------------------------------------------
type Visual = { part: BasePart, offset: CFrame }
type ClientItem = { id: string, model: Model, center: Vector3, visuals: { Visual }, effects: { Instance }, hidden: boolean }
local clientItems: { [string]: ClientItem } = {}
local collected: { [string]: boolean } = {}
local state: any = nil
local collectRemote: RemoteEvent? = nil
local lastAsk: { [string]: number } = {}

local function setHidden(item: ClientItem, hidden: boolean)
	item.hidden = hidden
	for _, v in item.visuals do
		v.part.LocalTransparencyModifier = if hidden then 1 else 0
	end
	for _, e in item.effects do
		if e:IsA("ParticleEmitter") or e:IsA("PointLight") then
			e.Enabled = not hidden
		end
	end
end

local function register(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local id = model:GetAttribute("Id")
	local center = model:GetAttribute("Center")
	if type(id) ~= "string" or typeof(center) ~= "Vector3" then
		return
	end
	local c = CFrame.new(center)
	local item: ClientItem = { id = id, model = model, center = center, visuals = {}, effects = {}, hidden = false }
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Spin") then
			table.insert(item.visuals, { part = d, offset = c:ToObjectSpace(d.CFrame) })
		elseif d:IsA("ParticleEmitter") or d:IsA("PointLight") then
			table.insert(item.effects, d)
		end
	end
	clientItems[id] = item
	setHidden(item, collected[id] == true)
end

local function burst(position: Vector3, color: Color3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(position)
	p.Parent = Workspace.CurrentCamera
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Speed = NumberRange.new(8, 16)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Lifetime = NumberRange.new(0.4, 0.8)
	e.Size = NumberSequence.new(0.5, 0)
	e.LightEmission = 1
	e.Color = ColorSequence.new(color)
	e.Parent = p
	e:Emit(30)
	task.delay(1.2, function()
		p:Destroy()
	end)
end

local function markCollected(id: string)
	collected[id] = true
	local item = clientItems[id]
	if item and not item.hidden then
		local set = item.model:GetAttribute("Set")
		local def = if type(set) == "string" then WC.SET_BY_ID[set] else nil
		burst(item.center, if def then def.color else Color3.new(1, 1, 1))
		setHidden(item, true)
	end
end

local function applyState(s: any)
	if type(s) ~= "table" then
		return
	end
	state = s
	table.clear(collected)
	for _, id in s.collected or {} do
		collected[id] = true
	end
	for id, item in clientItems do
		setHidden(item, collected[id] == true)
	end
	Phone.refresh("Collection")
end

local function startCollectibles()
	for _, m in CollectionService:GetTagged("Collectible") do
		register(m)
	end
	CollectionService:GetInstanceAddedSignal("Collectible"):Connect(register)
	CollectionService:GetInstanceRemovedSignal("Collectible"):Connect(function(m)
		local id = m:GetAttribute("Id")
		if type(id) == "string" then
			clientItems[id] = nil
		end
	end)

	-- spin + bob the items you can see
	RunService.RenderStepped:Connect(function()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local camPos = camera.CFrame.Position
		local t = os.clock()
		for _, item in clientItems do
			if not item.hidden and (item.center - camPos).Magnitude < 160 then
				local cf = CFrame.new(item.center + Vector3.new(0, math.sin(t * 2 + item.center.X) * 0.25, 0)) * CFrame.Angles(0, t * 1.6, 0)
				for _, v in item.visuals do
					v.part.CFrame = cf * v.offset
				end
			end
		end
	end)

	-- walk into an item: ask the server (it re-checks everything)
	task.spawn(function()
		while true do
			task.wait(0.25)
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") and collectRemote then
				local pos = hrp.Position
				local now = os.clock()
				for id, item in clientItems do
					if not collected[id] and (item.center - pos).Magnitude < 6 and now - (lastAsk[id] or 0) > 1.5 then
						lastAsk[id] = now
						collectRemote:FireServer(id)
					end
				end
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Weather
---------------------------------------------------------------------------
type Look = {
	density: number, -- Atmosphere.Density offset from the base
	haze: number,
	cover: number, -- Clouds.Cover
	cloudDensity: number,
	cloudColor: Color3,
	bright: number, -- ColorCorrection.Brightness
	sat: number,
	contrast: number,
	tint: Color3,
	rain: number, -- 0..1
}

local LOOKS: { [string]: Look } = {
	Clear = { density = 0, haze = 0, cover = 0.35, cloudDensity = 0.3, cloudColor = Color3.fromRGB(255, 255, 255), bright = 0, sat = 0, contrast = 0, tint = Color3.new(1, 1, 1), rain = 0 },
	Cloudy = { density = 0.06, haze = 0.6, cover = 0.75, cloudDensity = 0.6, cloudColor = Color3.fromRGB(200, 205, 212), bright = -0.03, sat = -0.12, contrast = 0, tint = Color3.fromRGB(240, 242, 248), rain = 0 },
	Rain = { density = 0.12, haze = 1.3, cover = 0.9, cloudDensity = 0.85, cloudColor = Color3.fromRGB(150, 155, 165), bright = -0.07, sat = -0.25, contrast = 0.03, tint = Color3.fromRGB(225, 232, 245), rain = 0.7 },
	Storm = { density = 0.18, haze = 1.8, cover = 0.96, cloudDensity = 0.95, cloudColor = Color3.fromRGB(110, 112, 125), bright = -0.12, sat = -0.35, contrast = 0.06, tint = Color3.fromRGB(210, 218, 240), rain = 1 },
	Fog = { density = 0.32, haze = 0.9, cover = 0.6, cloudDensity = 0.5, cloudColor = Color3.fromRGB(220, 222, 226), bright = -0.02, sat = -0.18, contrast = -0.05, tint = Color3.fromRGB(240, 242, 245), rain = 0 },
	Heatwave = { density = 0.03, haze = 1.0, cover = 0.1, cloudDensity = 0.2, cloudColor = Color3.fromRGB(255, 240, 225), bright = 0.03, sat = 0.12, contrast = 0.06, tint = Color3.fromRGB(255, 236, 212), rain = 0 },
}

local current: Look = table.clone(LOOKS.Clear)
local atmosphere: Atmosphere? = nil
local baseDensity, baseHaze = 0.3, 1.2
local clouds: Clouds? = nil
local grade: ColorCorrectionEffect
local rainPart: BasePart
local rainEmitter: ParticleEmitter
local flash = 0
local nextFlash = 0
local covered = false
local chip: TextLabel? = nil

local function weatherId(): string
	local id = Workspace:GetAttribute("Weather")
	return if type(id) == "string" and LOOKS[id] then id else "Clear"
end

-- 0.25..1 from the game's Graphics setting, else Roblox's own quality slider (Automatic = full).
local function qualityScale(): number
	local gfx = player:GetAttribute("Graphics")
	if gfx == "Low" or gfx == "Medium" or gfx == "High" then
		return if gfx == "Low" then 0.3 elseif gfx == "Medium" then 0.65 else 1
	end
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
	end)
	if not ok or type(level) ~= "number" or level <= 0 then
		return 1
	end
	return math.clamp(level / 7, 0.25, 1)
end

local function isNight(): boolean
	local t = Lighting.ClockTime
	return t < 6.3 or t > 17.7
end

local function lerpLook(a: Look, b: Look, k: number)
	a.density += (b.density - a.density) * k
	a.haze += (b.haze - a.haze) * k
	a.cover += (b.cover - a.cover) * k
	a.cloudDensity += (b.cloudDensity - a.cloudDensity) * k
	a.cloudColor = a.cloudColor:Lerp(b.cloudColor, k)
	a.bright += (b.bright - a.bright) * k
	a.sat += (b.sat - a.sat) * k
	a.contrast += (b.contrast - a.contrast) * k
	a.tint = a.tint:Lerp(b.tint, k)
	a.rain += (b.rain - a.rain) * k
end

local function updateChip()
	if not chip then
		return
	end
	local def = WC.WEATHER_BY_ID[weatherId()]
	chip.Text = if def then def.icon .. "  " .. def.label else "☀️  Clear"
end

local function startWeather()
	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "CityGrindWeather"
	grade.Parent = Lighting

	task.spawn(function()
		local a = Lighting:FindFirstChildOfClass("Atmosphere") or Lighting:WaitForChild("Atmosphere", 10)
		if a and a:IsA("Atmosphere") then
			atmosphere = a
			baseDensity, baseHaze = a.Density, a.Haze
		end
	end)
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local existing = terrain:FindFirstChildOfClass("Clouds")
		if existing then
			clouds = existing
		else
			local c = Instance.new("Clouds")
			c.Cover = 0.35
			c.Density = 0.3
			c.Parent = terrain
			clouds = c
		end
	end

	-- rain: one emitter above the camera (parts under the camera are local only)
	rainPart = Instance.new("Part")
	rainPart.Name = "WeatherRain"
	rainPart.Anchored = true
	rainPart.CanCollide = false
	rainPart.CanQuery = false
	rainPart.CanTouch = false
	rainPart.Transparency = 1
	rainPart.Size = Vector3.new(110, 1, 110)
	rainPart.Parent = Workspace.CurrentCamera
	rainEmitter = Instance.new("ParticleEmitter")
	rainEmitter.EmissionDirection = Enum.NormalId.Bottom
	rainEmitter.Speed = NumberRange.new(80, 95)
	rainEmitter.Lifetime = NumberRange.new(0.75, 0.95)
	rainEmitter.Size = NumberSequence.new(0.12)
	rainEmitter.Squash = NumberSequence.new(2.5)
	rainEmitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	rainEmitter.Color = ColorSequence.new(Color3.fromRGB(200, 212, 235))
	rainEmitter.Transparency = NumberSequence.new(0.35)
	rainEmitter.LightInfluence = 1
	rainEmitter.Acceleration = Vector3.new(2, 0, 1)
	rainEmitter.Rate = 0
	rainEmitter.Parent = rainPart

	local roofParams = RaycastParams.new()
	roofParams.FilterType = Enum.RaycastFilterType.Exclude
	roofParams.RespectCanCollide = true

	-- under a roof / indoors / underground: no rain on you
	task.spawn(function()
		while true do
			task.wait(0.25)
			local camera = Workspace.CurrentCamera
			if camera then
				local list: { Instance } = { camera }
				if player.Character then
					table.insert(list, player.Character)
				end
				roofParams.FilterDescendantsInstances = list
				local p = camera.CFrame.Position
				covered = p.Y > 400 or Workspace:Raycast(p, Vector3.new(0, 120, 0), roofParams) ~= nil
			end
		end
	end)

	Workspace:GetAttributeChangedSignal("Weather"):Connect(updateChip)

	local quality = qualityScale()
	local qualityAt = 0
	RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		if now - qualityAt > 5 then
			qualityAt = now
			quality = qualityScale()
		end
		local id = weatherId()
		local target = LOOKS[id]
		lerpLook(current, target, math.clamp(dt / 6, 0, 1)) -- ~6 s blends
		local night = isNight()
		local beach = player:GetAttribute("District") == "Beach"

		if atmosphere then
			atmosphere.Density = math.clamp(baseDensity + current.density, 0, 1)
			atmosphere.Haze = math.clamp(baseHaze + current.haze, 0, 10)
		end
		if clouds then
			clouds.Cover = current.cover
			clouds.Density = current.cloudDensity
			clouds.Color = current.cloudColor
		end

		-- lightning in storms
		if id == "Storm" and now >= nextFlash then
			nextFlash = now + 7 + math.random() * 12
			flash = 1
			task.delay(0.18, function()
				flash = math.max(flash, 0.7)
			end)
		end
		flash = math.max(0, flash - dt * 4)

		-- grading is gentler at night so it never fights the day/night look;
		-- a heatwave is felt most on the sand
		local dayK = if night then 0.4 else 1
		local heatK = if id == "Heatwave" and not night then (if beach then 1.4 else 1) else 1
		grade.Brightness = current.bright * dayK + flash * (if night then 0.45 else 0.3)
		grade.Saturation = current.sat * dayK * heatK
		grade.Contrast = current.contrast * dayK
		grade.TintColor = Color3.new(1, 1, 1):Lerp(current.tint, math.clamp(dayK * heatK, 0, 1))

		local camera = Workspace.CurrentCamera
		if camera then
			if rainPart.Parent ~= camera then
				rainPart.Parent = camera
			end
			rainPart.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, 38, 0))
		end
		rainEmitter.Rate = if covered then 0 else current.rain * 900 * quality
	end)
end

---------------------------------------------------------------------------
-- Pedestrian walk cycle (procedural; Motor6D.Transform is local)
---------------------------------------------------------------------------
type Walker = { model: Model, root: BasePart, motors: { [string]: Motor6D }, phase: number }
local walkers: { [Model]: Walker } = {}

local function addWalker(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local r = model:FindFirstChild("HumanoidRootPart")
	if not r or not r:IsA("BasePart") then
		return
	end
	local motors = {}
	for _, name in { "RightShoulder", "LeftShoulder", "RightHip", "LeftHip" } do
		local m = model:FindFirstChild(name, true)
		if m and m:IsA("Motor6D") then
			motors[name] = m
		end
	end
	walkers[model] = { model = model, root = r, motors = motors, phase = math.random() * 6 }
end

local function startWalkers()
	for _, m in CollectionService:GetTagged("CityNPC") do
		addWalker(m)
	end
	CollectionService:GetInstanceAddedSignal("CityNPC"):Connect(addWalker)
	CollectionService:GetInstanceRemovedSignal("CityNPC"):Connect(function(m)
		walkers[m :: any] = nil
	end)
	RunService.PreSimulation:Connect(function(dt)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local camPos = camera.CFrame.Position
		for model, w in walkers do
			if not model.Parent then
				walkers[model] = nil
				continue
			end
			if (w.root.Position - camPos).Magnitude > 140 then
				continue
			end
			local v = w.root.AssemblyLinearVelocity
			local speed = Vector3.new(v.X, 0, v.Z).Magnitude
			w.phase += dt * speed * 0.85
			local amp = math.clamp(speed / 8, 0, 1) * 0.6
			local swing = math.sin(w.phase) * amp
			local m = w.motors
			if m.RightHip then
				m.RightHip.Transform = CFrame.Angles(swing, 0, 0)
			end
			if m.LeftHip then
				m.LeftHip.Transform = CFrame.Angles(-swing, 0, 0)
			end
			if m.LeftShoulder then
				m.LeftShoulder.Transform = CFrame.Angles(swing * 0.8, 0, 0)
			end
			if m.RightShoulder then
				m.RightShoulder.Transform = if model:GetAttribute("Waving") then CFrame.identity else CFrame.Angles(-swing * 0.8, 0, 0)
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Collection app (phone)
---------------------------------------------------------------------------
local function districtOrder(): { string }
	local list = {}
	for _, d in DC.LIST do
		table.insert(list, d.id)
	end
	return list
end

local function buildApp(content: ScrollingFrame)
	local function render()
		Phone.clear(content)
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		-- weather
		local wcard = Phone.card(content, 58, nextOrder())
		local def = WC.WEATHER_BY_ID[weatherId()]
		local ends = Workspace:GetAttribute("WeatherEnds")
		local minutes = if type(ends) == "number" then math.max(0, math.ceil((ends - Workspace:GetServerTimeNow()) / 60)) else nil
		UI.label({ Text = "CITY WEATHER", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = wcard })
		UI.label({
			Text = (if def then def.icon .. "  " .. def.label else "Clear") .. (if minutes then string.format("  ·  changes in ~%d min", minutes) else ""),
			Font = UI.FONT_BOLD,
			TextSize = 14,
			Position = UDim2.fromOffset(0, 16),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = wcard,
		})

		if not state then
			local c = Phone.card(content, 50, nextOrder())
			UI.label({ Text = "Loading your collection...", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1), Parent = c })
			return
		end

		-- totals per set and district
		local totals: { [string]: number } = {}
		local byDistrict: { [string]: { [string]: { total: number, got: number } } } = {}
		local all, allGot = 0, 0
		for _, it in state.items or {} do
			totals[it.set] = (totals[it.set] or 0) + 1
			byDistrict[it.set] = byDistrict[it.set] or {}
			local entry = byDistrict[it.set][it.district] or { total = 0, got = 0 }
			byDistrict[it.set][it.district] = entry
			entry.total += 1
			all += 1
			if collected[it.id] then
				entry.got += 1
				allGot += 1
			end
		end

		local head = Phone.card(content, 64, nextOrder())
		UI.label({ Text = "COLLECTIBLES", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = head })
		UI.label({ Text = string.format("%d / %d found", allGot, all), Font = UI.FONT_BLACK, TextSize = 18, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 20), Parent = head })
		UI.label({
			Text = string.format("+$%d each · set bonus $%d", WC.ITEM_REWARD.cash, WC.SET_REWARD.cash),
			TextSize = 11,
			TextColor3 = colors.cash,
			Position = UDim2.fromOffset(0, 38),
			Size = UDim2.new(1, 0, 0, 14),
			Parent = head,
		})

		for _, set in WC.SETS do
			local total = totals[set.id] or 0
			if total == 0 then
				continue
			end
			local got = 0
			local lines = {}
			for _, did in districtOrder() do
				local e = byDistrict[set.id] and byDistrict[set.id][did]
				if e then
					got += e.got
					local left = e.total - e.got
					table.insert(lines, string.format("%s %s: %s", if left == 0 then "✓" else "•", DC.displayName(did), if left == 0 then "all found" else left .. " left"))
				end
			end
			local done = state.sets and state.sets[set.id]
			local h = 70 + #lines * 15
			local c = Phone.card(content, h, nextOrder())
			UI.label({ Text = set.icon .. "  " .. set.name, Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = set.color, Size = UDim2.new(1, -60, 0, 18), Parent = c })
			UI.label({ Text = string.format("%d/%d", got, total), Font = UI.FONT_BLACK, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.new(1, 0, 0, 18), Parent = c })
			UI.label({ Text = if done then "SET COMPLETE ✓" else set.blurb, TextSize = 11, TextColor3 = if done then colors.cash else colors.subtext, TextWrapped = true, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 26), Parent = c })
			local bar, setFill = UI.bar({ Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 0, 6) }, set.color)
			bar.Parent = c
			setFill(got / total)
			UI.label({
				Text = table.concat(lines, "\n"),
				TextSize = 12,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(0, 60),
				Size = UDim2.new(1, 0, 0, #lines * 15),
				Parent = c,
			})
		end

		-- secrets: names only once found, never positions
		local found = state.secrets or {}
		local total = state.secretTotal or #WC.SECRET_IDS
		local sc = Phone.card(content, 46 + math.max(1, #found) * 16, nextOrder())
		UI.label({ Text = string.format("🗝️  SECRETS  %d/%d", #found, total), Font = UI.FONT_BLACK, TextSize = 14, Size = UDim2.new(1, 0, 0, 18), Parent = sc })
		local names = {}
		for _, s in found do
			table.insert(names, "✓ " .. tostring(s.name))
		end
		UI.label({
			Text = if #names > 0 then table.concat(names, "\n") else "Nothing yet. Old towns keep old secrets...",
			TextSize = 12,
			TextColor3 = if #names > 0 then colors.text else colors.subtext,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(0, 22),
			Size = UDim2.new(1, 0, 0, math.max(1, #found) * 16),
			Parent = sc,
		})
	end
	return render
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function World.start()
	Phone.addApp({ id = "Collection", label = "Collection", icon = "🏆", color = Color3.fromRGB(200, 150, 40) }, function(content)
		return buildApp(content)
	end)

	-- weather chip, left of the stats card
	local gui = UI.new("ScreenGui", { Name = "CityGrindWorld", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = player:WaitForChild("PlayerGui") })
	chip = UI.label({
		Text = "☀️  Clear",
		Font = UI.FONT_BOLD,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundTransparency = 0.15,
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -252, 0, 12),
		Size = UDim2.fromOffset(130, 30),
		Parent = gui,
	}, { UI.corner(12) })
	HUD.slot("topRight", chip :: TextLabel, 5) -- stacks under the stats card
	updateChip()

	startWeather()
	startWalkers()
	startCollectibles()

	task.spawn(function()
		local event = remotes:WaitForChild("WorldEvent", 30)
		local request = remotes:WaitForChild("WorldRequest", 30)
		local collect = remotes:WaitForChild("WorldCollect", 30)
		if collect and collect:IsA("RemoteEvent") then
			collectRemote = collect
		end
		if event and event:IsA("RemoteEvent") then
			event.OnClientEvent:Connect(function(kind: any, a: any, b: any)
				if kind == "State" then
					applyState(a)
				elseif kind == "Collected" and type(a) == "string" then
					markCollected(a)
					if state then
						table.insert(state.collected, a)
					end
					Phone.refresh("Collection")
				elseif kind == "Secret" and type(a) == "string" then
					if state then
						table.insert(state.secrets, { id = a, name = if type(b) == "string" then b else a })
					end
					Phone.refresh("Collection")
				end
			end)
		end
		if request and request:IsA("RemoteFunction") then
			local ok, s = pcall(function()
				return request:InvokeServer("Get")
			end)
			if ok and s then
				applyState(s)
			end
		end
	end)
end

return World
