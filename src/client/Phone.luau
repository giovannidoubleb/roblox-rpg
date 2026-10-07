-- CITY GRIND: the phone (sections 15, 16). P / DPad-Up / on-screen button.
-- Taking it out tells the server, which puts a phone in your character's hand.
--
-- Built in: Profile, Map (with GPS), Alerts and Settings. The Bank app lives in
-- Bank.luau (client); it, Messages, Calls, CityTok, CityGram and the rest are
-- added to the home screen through Phone.addApp as each one is built for real (section 118).

local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local DistrictsConfig = require(shared:WaitForChild("DistrictsConfig"))
local remotes = shared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local colors = UI.colors

local Phone = {}

local PHONE_W, PHONE_H = 300, 620
local SCREEN_INSET = 10
local PHONE_TOP_GAP = 120 -- keeps the phone below the HUD card

local gui: ScreenGui
local phoneFrame: Frame
local uiScale: UIScale
local screen: Frame
local wallpaperGradient: UIGradient
local pages: { [string]: { frame: Frame, open: (() -> ())? } } = {}
local currentPage = "Home"
local isOpen = false
local battery = 100
local badge: TextLabel

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function applyWallpaper()
	local index = player:GetAttribute("Wallpaper") or 1
	local wp = Config.WALLPAPERS[index] or Config.WALLPAPERS[1]
	wallpaperGradient.Color = ColorSequence.new(wp.top, wp.bottom)
end

local function applyScale()
	local camera = Workspace.CurrentCamera
	local viewportH = if camera then camera.ViewportSize.Y else 800
	local fit = math.min(1, (viewportH - 2 * PHONE_TOP_GAP) / (PHONE_H + 20))
	uiScale.Scale = fit * (player:GetAttribute("UIScale") or 1)
end

local function showPage(name: string)
	for pageName, page in pages do
		page.frame.Visible = pageName == name
	end
	currentPage = name
	local page = pages[name]
	if page and page.open then
		task.spawn(page.open)
	end
end

-- Builds an app page with a header and scrolling content list.
local function appPage(name: string, title: string): (Frame, ScrollingFrame)
	local frame = UI.new("Frame", {
		Name = name,
		BackgroundColor3 = Color3.fromRGB(14, 14, 20),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = screen,
	})
	local header = UI.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 40),
		Parent = frame,
	})
	local back = UI.button({
		Text = "‹ Home",
		TextSize = 15,
		BackgroundTransparency = 1,
		TextColor3 = colors.xp,
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.fromOffset(70, 32),
		Parent = header,
	})
	back.Activated:Connect(function()
		showPage("Home")
	end)
	UI.label({
		Text = title,
		Font = UI.FONT_BLACK,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = header,
	})
	local content = UI.new("ScrollingFrame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 76),
		Size = UDim2.new(1, 0, 1, -104),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		UI.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 12) }),
	})
	pages[name] = { frame = frame }
	return frame, content
end

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function card(parent: Instance, height: number, order: number): Frame
	return UI.new("Frame", {
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, -20, 0, height),
		LayoutOrder = order,
		Parent = parent,
	}, { UI.corner(14), UI.padding(12) })
end

local function fetchProfile()
	local ok, result = pcall(function()
		return remotes.GetProfile:InvokeServer()
	end)
	return if ok then result else nil
end

---------------------------------------------------------------------------
-- Profile app
---------------------------------------------------------------------------
local function buildProfile()
	local _, content = appPage("Profile", "Profile")
	pages.Profile.open = function()
		clear(content)
		local data = fetchProfile()
		if not data then
			UI.label({ Text = "Profile is still loading...", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
			return
		end
		local top = card(content, 120, 1)
		local avatar = UI.new("ImageLabel", { BackgroundColor3 = colors.panel, Size = UDim2.fromOffset(72, 72), Parent = top }, { UI.corner(36) })
		task.spawn(function()
			local ok, image = pcall(function()
				return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
			end)
			if ok then
				avatar.Image = image
			end
		end)
		UI.label({ Text = player.DisplayName:upper(), Font = UI.FONT_BLACK, TextSize = 20, Position = UDim2.fromOffset(84, 2), Size = UDim2.new(1, -84, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd, Parent = top })
		UI.label({ Text = "LEVEL " .. data.level, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.xp, Position = UDim2.fromOffset(84, 26), Size = UDim2.new(1, -84, 0, 16), Parent = top })
		UI.label({ Text = data.rank:upper(), Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.accent, Position = UDim2.fromOffset(84, 44), Size = UDim2.new(1, -84, 0, 16), Parent = top })
		local _, setXP = UI.bar({ Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, 0, 0, 8), Parent = top }, colors.xp)
		setXP(data.xp / data.xpToNext)
		UI.label({ Text = string.format("%d / %d XP to level %d", data.xp, data.xpToNext, data.level + 1), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 92), Size = UDim2.new(1, 0, 0, 14), Parent = top })

		local numbers = card(content, 66, 2)
		local entries = {
			{ "Reputation", tostring(data.reputation) },
			{ "Fame", tostring(data.fame) },
			{ "Runs", tostring(data.runsCompleted) },
			{ "Best Run", if data.bestRunSeconds > 0 then string.format("%.1fs", data.bestRunSeconds) else "—" },
		}
		for i, entry in entries do
			local x = (i - 1) / #entries
			UI.label({ Text = entry[2], Font = UI.FONT_BLACK, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(x, 0), Size = UDim2.new(1 / #entries, 0, 0, 22), Parent = numbers })
			UI.label({ Text = entry[1], TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new(x, 0, 0, 24), Size = UDim2.new(1 / #entries, 0, 0, 14), Parent = numbers })
		end

		local bb = data.basketball or {}
		local hoops = card(content, 66, 3)
		local bbEntries = {
			{ "W - L", string.format("%d-%d", bb.wins or 0, bb.losses or 0) },
			{ "Points", tostring(bb.points or 0) },
			{ "3PT", tostring(bb.threes or 0) },
			{ "Dunks", tostring(bb.dunks or 0) },
		}
		for i, entry in bbEntries do
			local x = (i - 1) / #bbEntries
			UI.label({ Text = entry[2], Font = UI.FONT_BLACK, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(x, 0), Size = UDim2.new(1 / #bbEntries, 0, 0, 22), Parent = hoops })
			UI.label({ Text = entry[1], TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new(x, 0, 0, 24), Size = UDim2.new(1 / #bbEntries, 0, 0, 14), Parent = hoops })
		end

		local stats = card(content, 30 + #Config.STATS * 24, 4)
		UI.label({ Text = "ATTRIBUTES", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = stats })
		for i, stat in Config.STATS do
			local y = 22 + (i - 1) * 24
			local value = data.stats[stat] or 1
			UI.label({ Text = stat:gsub("(%l)(%u)", "%1 %2"), TextSize = 13, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(100, 18), Parent = stats })
			local _, setStat = UI.bar({ Position = UDim2.fromOffset(104, y + 5), Size = UDim2.new(1, -140, 0, 8), Parent = stats }, colors.accent)
			setStat(value / 99)
			UI.label({ Text = tostring(value), Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(30, 18), Parent = stats })
		end
	end
end

---------------------------------------------------------------------------
-- Map app with GPS (section 38)
---------------------------------------------------------------------------
local gps: { target: Vector3, name: string, beam: Beam, a0: Attachment, a1: Attachment, marker: BasePart }? = nil

local function clearGPS()
	if gps then
		gps.beam:Destroy()
		gps.a0:Destroy()
		gps.marker:Destroy()
		gps = nil
	end
end

local function setGPS(name: string, target: Vector3)
	clearGPS()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local marker = UI.new("Part", {
		Name = "GPSMarker",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Size = Vector3.one,
		Position = target + Vector3.new(0, 2, 0),
		Parent = Workspace,
	})
	local a1 = UI.new("Attachment", { Parent = marker })
	local a0 = UI.new("Attachment", { Position = Vector3.new(0, -2.5, 0), Parent = root })
	local beam = UI.new("Beam", {
		Attachment0 = a0,
		Attachment1 = a1,
		Color = ColorSequence.new(Color3.fromRGB(80, 200, 255)),
		Transparency = NumberSequence.new(0.2),
		Width0 = 1.2,
		Width1 = 1.2,
		FaceCamera = true,
		LightEmission = 1,
		Segments = 1,
		Parent = marker,
	})
	local billboard = UI.new("BillboardGui", { Size = UDim2.fromOffset(200, 50), StudsOffset = Vector3.new(0, 8, 0), AlwaysOnTop = true, LightInfluence = 0, Parent = marker })
	local label = UI.label({ Name = "Text", Text = name, Font = UI.FONT_BLACK, TextSize = 18, TextStrokeTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = billboard })
	gps = { target = target, name = name, beam = beam, a0 = a0, a1 = a1, marker = marker }
	HUD.push("GPS SET", "Follow the blue line to " .. name .. ".")

	task.spawn(function()
		local myGps = gps
		while gps == myGps do
			local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r then
				if a0.Parent ~= r then
					a0.Parent = r -- respawned
				end
				local dist = (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude
				label.Text = string.format("%s  ·  %dm", name, math.floor(dist / 3.57)) -- ~3.57 studs per metre
				if dist < 14 then
					clearGPS()
					HUD.push("ARRIVED", "You made it to " .. name .. ".")
					return
				end
			end
			task.wait(0.2)
		end
	end)
end

local function buildMap()
	local _, content = appPage("Map", "Map")
	local MAP_W = PHONE_W - 2 * SCREEN_INSET - 20
	local MAP_H = 300
	-- the whole city (every district), from DistrictsConfig
	local MIN_X, MIN_Z = DistrictsConfig.MAP_MIN.X, DistrictsConfig.MAP_MIN.Z
	local WORLD_W = DistrictsConfig.MAP_MAX.X - MIN_X
	local WORLD_H = DistrictsConfig.MAP_MAX.Z - MIN_Z
	local BASE_SCALE = MAP_W / WORLD_W -- pixels per stud at zoom 1 (whole city fits)
	local ZOOMS = { 1, 1.6, 2.5, 4, 6 }
	local zoomIndex = 3
	local view = Vector2.new(0, 0) -- world X/Z shown at the canvas centre
	local follow = true -- keep the player centred until they pan

	-- CanvasGroup so rotated shapes (curves, ramps) are clipped too
	local canvas = UI.new("CanvasGroup", {
		Name = "Canvas",
		BackgroundColor3 = Color3.fromRGB(30, 36, 44),
		Size = UDim2.fromOffset(MAP_W, MAP_H),
		LayoutOrder = 1,
		Parent = content,
	}, { UI.corner(12) })
	local world = UI.new("Frame", { Name = "World", BackgroundTransparency = 1, Parent = canvas })

	local function frac(pos: Vector3): UDim2
		return UDim2.fromScale((pos.X - MIN_X) / WORLD_W, (pos.Z - MIN_Z) / WORLD_H)
	end

	local function applyView()
		local s = BASE_SCALE * ZOOMS[zoomIndex]
		view = Vector2.new(math.clamp(view.X, MIN_X, MIN_X + WORLD_W), math.clamp(view.Y, MIN_Z, MIN_Z + WORLD_H))
		world.Size = UDim2.fromOffset(WORLD_W * s, WORLD_H * s)
		world.Position = UDim2.fromOffset(MAP_W / 2 - (view.X - MIN_X) * s, MAP_H / 2 - (view.Y - MIN_Z) * s)
	end

	-- A part's footprint as a (possibly rotated) rectangle.
	local function rect(part: BasePart, color: Color3, z: number)
		local cf, size = part.CFrame, part.Size
		local rv, lv = cf.RightVector, cf.LookVector
		local w, d, rot = size.X, size.Z, 0
		if math.abs(rv.Y) < 0.5 then
			rot = math.deg(math.atan2(rv.Z, rv.X))
			d = size.Z * Vector2.new(lv.X, lv.Z).Magnitude
		end
		UI.new("Frame", {
			Name = "Shape",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color,
			Position = frac(cf.Position),
			Size = UDim2.new(w / WORLD_W, 1, d / WORLD_H, 1),
			Rotation = rot,
			ZIndex = z,
			Parent = world,
		})
	end

	local arrow = UI.label({
		Text = "▲",
		Font = UI.FONT_BLACK,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(80, 200, 255),
		TextStrokeTransparency = 0,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
		ZIndex = 10,
		Parent = world,
	})

	-- district names
	for _, d in DistrictsConfig.LIST do
		UI.label({
			Name = "DistrictLabel",
			Text = string.upper(d.name),
			Font = UI.FONT_BLACK,
			TextSize = 11,
			TextColor3 = d.color,
			TextStrokeTransparency = 0.2,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = frac(d.center),
			Size = UDim2.fromOffset(120, 14),
			ZIndex = 8,
			Parent = world,
		})
	end

	-- zoom / recentre controls (touch, mouse and gamepad friendly buttons)
	local controls = UI.new("Frame", { Name = "Controls", BackgroundTransparency = 1, Size = UDim2.fromOffset(MAP_W, 30), LayoutOrder = 2, Parent = content })
	local whereLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -120, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = controls })
	local function control(text: string, x: number, fn: () -> ())
		local b = UI.button({ Text = text, TextSize = 15, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, x, 0, 0), Size = UDim2.fromOffset(36, 30), Parent = controls })
		b.Activated:Connect(fn)
	end
	control("−", -80, function()
		zoomIndex = math.max(1, zoomIndex - 1)
		applyView()
	end)
	control("+", -40, function()
		zoomIndex = math.min(#ZOOMS, zoomIndex + 1)
		applyView()
	end)
	control("◎", 0, function()
		follow = true
	end)

	-- drag to pan, mouse wheel to zoom
	local dragInput: InputObject? = nil
	local dragStart = Vector3.zero
	local dragView = view
	canvas.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
			dragStart = input.Position
			dragView = view
			content.ScrollingEnabled = false
		end
	end)
	canvas.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoomIndex = math.clamp(zoomIndex + (if input.Position.Z > 0 then 1 else -1), 1, #ZOOMS)
			applyView()
		end
	end)
	canvas.MouseEnter:Connect(function()
		content.ScrollingEnabled = false -- the wheel zooms the map instead of scrolling the list
	end)
	canvas.MouseLeave:Connect(function()
		if not dragInput then
			content.ScrollingEnabled = true
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragInput then
			return
		end
		local moving = (dragInput.UserInputType == Enum.UserInputType.Touch and input == dragInput)
			or (dragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
		if moving then
			local delta = input.Position - dragStart
			if delta.Magnitude > 4 then
				follow = false
			end
			if not follow then
				local s = BASE_SCALE * ZOOMS[zoomIndex] * (if uiScale then uiScale.Scale else 1)
				view = dragView - Vector2.new(delta.X, delta.Y) / s
				applyView()
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragInput and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragInput = nil
			content.ScrollingEnabled = true
		end
	end)

	local drawnParts = -1
	local function drawCity()
		local city = Workspace:FindFirstChild("City")
		if not city then
			return
		end
		-- collect what the map draws; redraw only when that set changed (e.g. districts
		-- finished streaming in), not when NPCs, vehicles or speech bubbles come and go
		local shapes: { { part: BasePart, color: Color3, z: number } } = {}
		for _, d in city:GetDescendants() do
			if d:IsA("BasePart") and d.Position.Y < 400 then
				local mapColor = d:GetAttribute("MapColor")
				if typeof(mapColor) == "Color3" then
					local layer = d:GetAttribute("MapLayer")
					table.insert(shapes, { part = d, color = mapColor, z = if type(layer) == "number" then layer else 2 })
				elseif d.Name == "Ground" and d.Parent and d.Parent.Name == "Streets" then
					table.insert(shapes, { part = d, color = Color3.fromRGB(86, 140, 70), z = 1 })
				elseif d.Name == "MainRoad" or d.Name == "CrossRoad" then
					table.insert(shapes, { part = d, color = Color3.fromRGB(50, 50, 55), z = 2 })
				elseif d.Name == "Sidewalk" then
					table.insert(shapes, { part = d, color = Color3.fromRGB(170, 170, 165), z = 2 })
				elseif d.Name == "Body" and d.Parent and d.Parent.Parent and d.Parent.Parent.Name == "Buildings" then
					table.insert(shapes, { part = d, color = Color3.fromRGB(200, 190, 175), z = 3 })
				elseif d.Name == "CourtFloor" then
					table.insert(shapes, { part = d, color = Color3.fromRGB(40, 90, 150), z = 4 })
				elseif d.Name == "Lot" then
					table.insert(shapes, { part = d, color = Color3.fromRGB(60, 60, 66), z = 2 })
				end
			end
		end
		if #shapes == drawnParts then
			return
		end
		drawnParts = #shapes
		for _, child in world:GetChildren() do
			if child.Name == "Shape" then
				child:Destroy()
			end
		end
		for _, sh in shapes do
			rect(sh.part, sh.color, sh.z)
		end
	end

	local listStart = 3
	local showAll = false
	local NEAREST = 30
	pages.Map.open = function()
		drawCity()
		applyView()
		for _, child in content:GetChildren() do
			if child:IsA("GuiObject") and child ~= canvas and child ~= controls then
				child:Destroy()
			end
		end
		for _, child in world:GetChildren() do
			if child.Name == "Dot" then
				child:Destroy()
			end
		end
		local city = Workspace:FindFirstChild("City")
		local points = city and city:FindFirstChild("MapPoints")
		if gps then
			local clearRow = UI.button({ Text = "Clear GPS to " .. gps.name, TextSize = 13, BackgroundColor3 = colors.danger, Size = UDim2.new(1, -20, 0, 34), LayoutOrder = listStart, Parent = content })
			clearRow.Activated:Connect(function()
				clearGPS()
				showPage("Map")
			end)
		end
		if not points then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local list = {}
		for _, point in points:GetChildren() do
			if point:IsA("BasePart") then
				table.insert(list, point)
			end
		end
		table.sort(list, function(a, b)
			if not root then
				return a.Name < b.Name
			end
			return (a.Position - root.Position).Magnitude < (b.Position - root.Position).Magnitude
		end)
		for i, point in list do
			-- every place gets a dot; the list shows the nearest ones unless expanded
			UI.new("Frame", {
				Name = "Dot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = if point:GetAttribute("Category") == "Transit" then Color3.fromRGB(80, 200, 255) else colors.accent,
				Position = frac(point.Position),
				Size = UDim2.fromOffset(6, 6),
				ZIndex = 6,
				Parent = world,
			}, { UI.corner(3) })
			if showAll or i <= NEAREST then
				local row = card(content, 44, listStart + i)
				UI.label({ Text = point.Name, Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -70, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				local dist = if root then math.floor((point.Position - root.Position).Magnitude / 3.57) .. "m" else ""
				local district = DistrictsConfig.displayName(DistrictsConfig.at(point.Position))
				UI.label({ Text = (point:GetAttribute("Category") or "Place") .. "  ·  " .. district .. "  ·  " .. dist, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -70, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				local go = UI.button({ Text = "GPS", TextSize = 13, BackgroundColor3 = Color3.fromRGB(40, 120, 220), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(56, 28), Parent = row })
				go.Activated:Connect(function()
					setGPS(point.Name, point.Position)
					showPage("Map")
				end)
			end
		end
		if not showAll and #list > NEAREST then
			local more = UI.button({ Text = string.format("Show all %d places", #list), TextSize = 13, Size = UDim2.new(1, -20, 0, 34), LayoutOrder = listStart + #list + 1, Parent = content })
			more.Activated:Connect(function()
				showAll = true
				showPage("Map")
			end)
		end
	end

	RunService.RenderStepped:Connect(function()
		if not isOpen or currentPage ~= "Map" then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			arrow.Position = frac(root.Position)
			local look = root.CFrame.LookVector
			arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))
			if follow then
				view = Vector2.new(root.Position.X, root.Position.Z)
				applyView()
			end
			whereLabel.Text = "📍 " .. DistrictsConfig.displayName(DistrictsConfig.at(root.Position))
		end
	end)
end

---------------------------------------------------------------------------
-- Alerts app (section 36)
---------------------------------------------------------------------------
local function buildAlerts()
	local _, content = appPage("Alerts", "Notifications")
	pages.Alerts.open = function()
		HUD.markRead()
		clear(content)
		if #HUD.notifications == 0 then
			UI.label({ Text = "No notifications yet.", TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 40), Parent = content })
			return
		end
		local clearAll = UI.button({ Text = "Clear all", TextSize = 13, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = 0, Parent = content })
		clearAll.Activated:Connect(function()
			table.clear(HUD.notifications)
			showPage("Alerts")
		end)
		for i, n in HUD.notifications do
			local row = card(content, 58, i)
			UI.label({ Text = n.title, Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.accent, Size = UDim2.new(1, -60, 0, 14), Parent = row })
			UI.label({ Text = UI.timeAgo(n.time), TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(60, 14), Parent = row })
			UI.label({ Text = n.body, TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 18), Parent = row })
		end
	end
end

---------------------------------------------------------------------------
-- Settings app (section 43)
---------------------------------------------------------------------------
local function setSetting(key: string, value: any)
	local ok, accepted = pcall(function()
		return remotes.SetSetting:InvokeServer(key, value)
	end)
	if not ok or not accepted then
		HUD.push("SETTINGS", "That change didn't save. Try again in a moment.")
	end
end

local function buildSettings()
	local _, content = appPage("Settings", "Settings")
	pages.Settings.open = function()
		clear(content)

		local wp = card(content, 92, 1)
		UI.label({ Text = "WALLPAPER", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = wp })
		local current = player:GetAttribute("Wallpaper") or 1
		for i, paper in Config.WALLPAPERS do
			local swatch = UI.new("TextButton", {
				Text = "",
				BackgroundColor3 = Color3.new(1, 1, 1),
				Position = UDim2.fromOffset((i - 1) * 48, 22),
				Size = UDim2.fromOffset(40, 44),
				Parent = wp,
			}, {
				UI.corner(10),
				UI.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(paper.top, paper.bottom) }),
			})
			if i == current then
				UI.stroke(Color3.new(1, 1, 1), 2).Parent = swatch
			end
			swatch.Activated:Connect(function()
				setSetting("wallpaper", i)
				task.wait(0.2)
				showPage("Settings")
			end)
		end

		local scaleCard = card(content, 70, 2)
		UI.label({ Text = "PHONE SIZE", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = scaleCard })
		local currentScale = player:GetAttribute("UIScale") or 1
		for i, s in Config.UI_SCALES do
			local b = UI.button({
				Text = math.floor(s * 100) .. "%",
				TextSize = 12,
				BackgroundColor3 = if s == currentScale then colors.xp else colors.panel,
				Position = UDim2.fromOffset((i - 1) * 50, 22),
				Size = UDim2.fromOffset(46, 28),
				Parent = scaleCard,
			})
			b.Activated:Connect(function()
				setSetting("uiScale", s)
				task.wait(0.2)
				showPage("Settings")
			end)
		end

		local soundCard = card(content, 50, 3)
		UI.label({ Text = "Notification sounds", Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -70, 1, 0), Parent = soundCard })
		local soundsOn = player:GetAttribute("NotificationSounds") ~= false
		local toggle = UI.button({
			Text = if soundsOn then "ON" else "OFF",
			TextSize = 13,
			BackgroundColor3 = if soundsOn then Color3.fromRGB(50, 170, 90) else colors.panel,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(56, 28),
			Parent = soundCard,
		})
		toggle.Activated:Connect(function()
			setSetting("notificationSounds", not soundsOn)
			task.wait(0.2)
			showPage("Settings")
		end)

		local about = card(content, 50, 4)
		UI.label({ Text = "CityPhone · " .. player.Name, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = about })
		UI.label({ Text = "Settings are saved to your account.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 14), Parent = about })
	end
end

---------------------------------------------------------------------------
-- Home screen (section 16)
---------------------------------------------------------------------------
local APPS = {
	{ id = "Profile", label = "Profile", icon = "👤", color = Color3.fromRGB(90, 110, 240) },
	{ id = "Map", label = "Map", icon = "🗺️", color = Color3.fromRGB(240, 150, 40) },
	{ id = "Alerts", label = "Alerts", icon = "🔔", color = Color3.fromRGB(230, 70, 80) },
	{ id = "Settings", label = "Settings", icon = "⚙️", color = Color3.fromRGB(55, 55, 68) },
}

-- Apps added by other client systems (Jobs, Garage...) through Phone.addApp.
type ExtraApp = { id: string, label: string, icon: string, color: Color3, build: (content: ScrollingFrame, frame: Frame) -> (() -> ())? }
local extraApps: { ExtraApp } = {}

local function buildHome()
	local home = UI.new("Frame", { Name = "Home", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = screen })
	pages.Home = { frame = home }

	local bigClock = UI.label({ Text = "9:00", Font = UI.FONT_BLACK, TextSize = 56, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 60), Parent = home })
	local subtitle = UI.label({ Text = "The Neighborhood", Font = UI.FONT_BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 120), Size = UDim2.new(1, 0, 0, 18), Parent = home })

	-- Scrolls once there are more apps than fit on one screen.
	local grid = UI.new("ScrollingFrame", {
		Name = "Apps",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 150),
		Size = UDim2.new(1, -28, 1, -186),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = home,
	}, {
		UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(60, 80), CellPadding = UDim2.fromOffset(6, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local allApps = table.clone(APPS)
	for _, app in extraApps do
		-- extra apps go before Settings so Settings stays last
		table.insert(allApps, #allApps, app)
	end
	for i, app in allApps do
		local cell = UI.new("Frame", { Name = app.id, BackgroundTransparency = 1, LayoutOrder = i, Parent = grid })
		local icon = UI.new("TextButton", {
			Name = "Icon",
			Text = app.icon,
			TextSize = 28,
			Font = UI.FONT,
			BackgroundColor3 = app.color,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(56, 56),
			AutoButtonColor = true,
			Parent = cell,
		}, { UI.corner(14) })
		UI.label({ Text = app.label, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.6, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 14), Parent = cell })
		icon.Activated:Connect(function()
			showPage(app.id)
		end)
		if app.id == "Alerts" then
			badge = UI.new("TextLabel", {
				Text = "0",
				Font = UI.FONT_BLACK,
				TextSize = 12,
				TextColor3 = Color3.new(1, 1, 1),
				BackgroundColor3 = Color3.fromRGB(255, 50, 50),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(1, -2, 0, 2),
				Size = UDim2.fromOffset(20, 20),
				Visible = false,
				ZIndex = 3,
				Parent = icon,
			}, { UI.corner(10) })
		end
	end

	RunService.Heartbeat:Connect(function()
		if isOpen and currentPage == "Home" then
			bigClock.Text = UI.formatClock(Lighting.ClockTime):gsub(" [AP]M", "")
			subtitle.Text = DistrictsConfig.displayName(player:GetAttribute("District")) .. "  ·  " .. (if Lighting.ClockTime >= 6 and Lighting.ClockTime < 18 then "Day" else "Night")
		end
	end)
end

local function buildStatusBar()
	local bar = UI.new("Frame", { Name = "StatusBar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), ZIndex = 20, Parent = screen }, { UI.padding(8) })
	local clock = UI.label({ Text = "9:00 AM", Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(0.4, 0, 1, 0), ZIndex = 20, Parent = bar })
	local right = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.6, 0, 1, 0), ZIndex = 20, Parent = bar })
	local bell = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.4, 0), Size = UDim2.new(0.2, 0, 1, 0), ZIndex = 20, Parent = bar })

	local function refreshBadge()
		local unread = HUD.unread
		if badge then
			badge.Visible = unread > 0
			badge.Text = if unread > 9 then "9+" else tostring(unread)
		end
		bell.Text = if unread > 0 then "🔔" .. unread else ""
	end
	HUD.notificationAdded.Event:Connect(refreshBadge)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		-- The battery drains while the phone is out and charges while it's away.
		accumulator += dt
		if accumulator >= 1 then
			accumulator -= 1
			battery = if isOpen then math.max(5, battery - 0.08) else math.min(100, battery + 0.5)
		end
		if isOpen then
			clock.Text = UI.formatClock(Lighting.ClockTime)
			right.Text = string.format("▂▄▆█  %d%%", math.floor(battery))
		end
	end)
	refreshBadge()
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------
function Phone.setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	applyScale()
	phoneFrame.Visible = true
	local target = if open then UDim2.new(1, -24, 0.5, PHONE_TOP_GAP / 2) else UDim2.new(1, PHONE_W + 40, 0.5, PHONE_TOP_GAP / 2)
	local tween = TweenService:Create(phoneFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = target })
	tween:Play()
	if open then
		showPage(currentPage)
	else
		tween.Completed:Once(function()
			if not isOpen then
				phoneFrame.Visible = false
			end
		end)
	end
	remotes.PhoneState:FireServer(open)
end

-- Registers a phone app. Call before Phone.start().
-- build(content, frame) fills the page once; it may return an `open` function
-- that runs every time the app is opened (use it to refresh live data).
function Phone.addApp(app: { id: string, label: string, icon: string, color: Color3 }, build: (content: ScrollingFrame, frame: Frame) -> (() -> ())?)
	table.insert(extraApps, { id = app.id, label = app.label, icon = app.icon, color = app.color, build = build })
end

-- Helpers for app pages.
Phone.card = card -- (parent, height, layoutOrder) -> rounded Frame
Phone.clear = clear -- removes everything but layouts/padding
Phone.setGPS = function(name: string, target: Vector3)
	setGPS(name, target)
end
Phone.clearGPS = function()
	clearGPS()
end
Phone.width = PHONE_W - 2 * SCREEN_INSET

function Phone.showPage(name: string)
	showPage(name)
end

function Phone.isOpen(): boolean
	return isOpen
end

function Phone.currentPage(): string
	return currentPage
end

-- Re-runs an app's open function if it is on screen right now.
function Phone.refresh(id: string)
	if isOpen and currentPage == id then
		showPage(id)
	end
end

function Phone.toggle()
	Phone.setOpen(not isOpen)
end

function Phone.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindPhone",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
		Parent = player:WaitForChild("PlayerGui"),
	})
	phoneFrame = UI.new("Frame", {
		Name = "Phone",
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, PHONE_W + 40, 0.5, PHONE_TOP_GAP / 2),
		Size = UDim2.fromOffset(PHONE_W, PHONE_H),
		Visible = false,
		Parent = gui,
	}, { UI.corner(42), UI.stroke(Color3.fromRGB(70, 70, 80), 2) })
	uiScale = UI.new("UIScale", { Parent = phoneFrame })

	screen = UI.new("Frame", {
		Name = "Screen",
		BackgroundColor3 = Color3.new(1, 1, 1),
		ClipsDescendants = true,
		Position = UDim2.fromOffset(SCREEN_INSET, SCREEN_INSET),
		Size = UDim2.new(1, -2 * SCREEN_INSET, 1, -2 * SCREEN_INSET),
		Parent = phoneFrame,
	}, { UI.corner(34) })
	wallpaperGradient = UI.new("UIGradient", { Rotation = 90, Parent = screen })

	-- notch
	UI.new("Frame", { BackgroundColor3 = Color3.fromRGB(10, 10, 12), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(90, 22), ZIndex = 30, Parent = screen }, { UI.corner(11) })

	buildStatusBar()
	buildHome()
	buildProfile()
	buildMap()
	buildAlerts()
	buildSettings()
	for _, app in extraApps do
		local frame, content = appPage(app.id, app.label)
		local ok, open = pcall(app.build, content, frame)
		if ok then
			pages[app.id].open = open
		else
			warn("[CityGrind] phone app " .. app.id .. " failed:", open)
		end
	end
	showPage("Home")

	-- Home indicator: tap to go home, tap again on Home to put the phone away.
	local homeBar = UI.new("TextButton", {
		Name = "HomeBar",
		Text = "",
		BackgroundColor3 = Color3.fromRGB(230, 230, 235),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(110, 6),
		ZIndex = 30,
		Parent = screen,
	}, { UI.corner(3) })
	local hitArea = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(160, 26), ZIndex = 31, Parent = screen })
	local function onHome()
		if currentPage == "Home" then
			Phone.setOpen(false)
		else
			showPage("Home")
		end
	end
	homeBar.Activated:Connect(onHome)
	hitArea.Activated:Connect(onHome)

	applyWallpaper()
	player:GetAttributeChangedSignal("Wallpaper"):Connect(applyWallpaper)
	player:GetAttributeChangedSignal("UIScale"):Connect(applyScale)
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end
	applyScale()

	ContextActionService:BindAction("CityPhone", function(_, state)
		if state == Enum.UserInputState.Begin then
			Phone.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.P, Enum.KeyCode.DPadUp)
	ContextActionService:SetTitle("CityPhone", "Phone")
	ContextActionService:SetPosition("CityPhone", UDim2.new(1, -110, 1, -200))

	player.CharacterAdded:Connect(function()
		-- the server removed the phone prop with the old character
		if isOpen then
			task.wait(0.5)
			remotes.PhoneState:FireServer(true)
		end
	end)
end

return Phone
