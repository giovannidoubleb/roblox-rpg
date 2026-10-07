-- CITY GRIND: vehicles on the client.
-- * Budget Wheels purchase panel and the Paint & Mods panel (opened by the
--   server when you use a showroom / kiosk prompt).
-- * Garage phone app: spawn / put away / locate owned vehicles.
-- * Driving: while you sit in the driver seat of your own vehicle your client
--   owns its physics and runs VehiclesConfig.step every frame, reading the
--   VehicleSeat's ThrottleFloat / SteerFloat (keyboard, gamepad and the mobile
--   thumbstick all feed those). H / Y / on-screen button toggles headlights.
-- * Visuals for every nearby vehicle: wheels spin, steer and follow the
--   suspension; headlights at night; brake lights.
-- Every purchase, mod and spawn is validated by the server.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local VC = require(shared:WaitForChild("VehiclesConfig"))
local remotes = shared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local colors = UI.colors

local Vehicles = {}

local TAG = "CityVehicle"
local LIGHTS_ACTION = "CityVehicleLights"

local gui: ScreenGui
local panel: Frame
local panelScale: UIScale
local panelBody: Frame
local panelCleanup: { () -> () } = {}
local panelMode: string? = nil
local panelAnchor: Vector3? = nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function remote(name: string): any
	return remotes:WaitForChild(name)
end

type Owned = { [string]: { paint: number, rim: number, glow: number } }

local function ownedVehicles(): Owned
	local json = player:GetAttribute("VehiclesOwned")
	if type(json) ~= "string" then
		return {}
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function sortedOwned(): { VC.Spec }
	local list = {}
	for id in ownedVehicles() do
		local s = VC.byId[id]
		if s then
			table.insert(list, s)
		end
	end
	table.sort(list, function(a, b)
		return a.price < b.price
	end)
	return list
end

local function myVehicle(): Model?
	for _, model in CollectionService:GetTagged(TAG) do
		if model:IsA("Model") and model:GetAttribute("Owner") == player.UserId then
			return model
		end
	end
	return nil
end

local function characters(): { Instance }
	local list = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

local function mph(studsPerSecond: number): number
	return math.floor(math.abs(studsPerSecond) * VC.MPH_PER_STUD + 0.5)
end

local function swatch(parent: Instance, color: Color3, size: number, order: number): TextButton
	local b = UI.new("TextButton", {
		Text = "",
		Font = UI.FONT_BLACK,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		AutoButtonColor = true,
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(size, size),
		LayoutOrder = order,
		Parent = parent,
	}, { UI.corner(size // 2) })
	return b
end

local function row(parent: Instance, y: number, height: number): Frame
	return UI.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, height),
		Parent = parent,
	}, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }),
	})
end

---------------------------------------------------------------------------
-- 3D preview (a clone of the showroom model in a ViewportFrame)
---------------------------------------------------------------------------
local function showroomModel(id: string): Model?
	local city = workspace:FindFirstChild("City")
	local root = city and city:FindFirstChild("Vehicles")
	local showroom = root and root:FindFirstChild("Showroom")
	local model = showroom and showroom:FindFirstChild("Display_" .. id)
	return if model and model:IsA("Model") then model else nil
end

local function recolor(model: Model, paintIndex: number, rimIndex: number, glowIndex: number)
	local paintColor = (VC.PAINTS[paintIndex] or VC.PAINTS[1]).color
	local rim = VC.RIMS[rimIndex] or VC.RIMS[1]
	local glow = VC.GLOWS[glowIndex] or VC.GLOWS[1]
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d:GetAttribute("Paint") then
				d.Color = paintColor
			elseif d:GetAttribute("Rim") then
				d.Color = rim.color
				d.Material = rim.material
			elseif d:GetAttribute("Glow") then
				d.Color = glow.color
				d.Transparency = if glowIndex == 1 then 1 else 0
			end
		end
	end
end

-- Returns a function that recolors the preview.
local function preview(parent: Instance, id: string, y: number, height: number): (number, number, number) -> ()
	local vp = UI.new("ViewportFrame", {
		BackgroundColor3 = Color3.fromRGB(28, 30, 40),
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, height),
		Ambient = Color3.fromRGB(150, 150, 160),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-1, -2, -1),
		Parent = parent,
	}, { UI.corner(12) })
	local source = showroomModel(id)
	if not source then
		UI.label({ Text = "Preview loading... walk closer to the showroom.", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = vp })
		return function() end
	end
	local clone = source:Clone()
	for _, d in clone:GetDescendants() do
		if d:IsA("ProximityPrompt") or d:IsA("SurfaceGui") or d:IsA("Light") then
			d:Destroy()
		end
	end
	clone:PivotTo(CFrame.new())
	clone.Parent = vp
	local camera = Instance.new("Camera")
	camera.FieldOfView = 35
	camera.Parent = vp
	vp.CurrentCamera = camera
	local extents = clone:GetExtentsSize()
	local radius = math.max(extents.X, extents.Z, extents.Y * 1.6)
	local distance = radius * 1.75
	camera.CFrame = CFrame.lookAt(Vector3.new(0, radius * 0.45, distance), Vector3.new(0, -extents.Y * 0.1, 0))
	local angle = math.rad(-35)
	local conn = RunService.RenderStepped:Connect(function(dt)
		angle += dt * 0.5
		clone:PivotTo(CFrame.Angles(0, angle, 0))
	end)
	table.insert(panelCleanup, function()
		conn:Disconnect()
	end)
	return function(p: number, r: number, g: number)
		recolor(clone, p, r, g)
	end
end

local function statBars(parent: Instance, s: VC.Spec, y: number): number
	local entries = {
		{ "TOP SPEED", s.topSpeed / VC.STAT_MAX.topSpeed, mph(s.topSpeed) .. " mph" },
		{ "ACCELERATION", s.accel / VC.STAT_MAX.accel },
		{ "HANDLING", s.handling / VC.STAT_MAX.handling },
		{ "BRAKING", s.brake / VC.STAT_MAX.brake },
		{ "GRIP", s.grip / VC.STAT_MAX.grip },
	}
	for i, e in entries do
		local ry = y + (i - 1) * 21
		UI.label({ Text = e[1], Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, ry), Size = UDim2.fromOffset(110, 16), Parent = parent })
		local _, setFill = UI.bar({ Position = UDim2.fromOffset(112, ry + 4), Size = UDim2.new(1, -182, 0, 8), Parent = parent }, colors.accent)
		setFill(e[2])
		UI.label({
			Text = e[3] or (tostring(math.clamp(math.round(e[2] * 10), 1, 10)) .. "/10"),
			Font = UI.FONT_BOLD,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, ry),
			Size = UDim2.fromOffset(64, 16),
			Parent = parent,
		})
	end
	return y + #entries * 21
end

---------------------------------------------------------------------------
-- Panel shell
---------------------------------------------------------------------------
local function closePanel()
	for _, fn in panelCleanup do
		pcall(fn)
	end
	table.clear(panelCleanup)
	if panelBody then
		panelBody:Destroy()
	end
	panel.Visible = false
	panelMode = nil
	panelAnchor = nil
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
end

-- Clears the panel and returns a fresh body frame plus a status label.
local function openPanel(mode: string, title: string, subtitle: string, height: number, anchor: Vector3): (Frame, TextLabel)
	for _, fn in panelCleanup do
		pcall(fn)
	end
	table.clear(panelCleanup)
	if panelBody then
		panelBody:Destroy()
	end
	panelMode = mode
	panelAnchor = anchor
	panel.Size = UDim2.fromOffset(380, height + 24)
	panelBody = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = panel })
	UI.label({ Text = title, Font = UI.FONT_BLACK, TextSize = 22, Size = UDim2.new(1, -44, 0, 26), TextTruncate = Enum.TextTruncate.AtEnd, Parent = panelBody })
	UI.label({ Text = subtitle, Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.accent, Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, -44, 0, 16), Parent = panelBody })
	local close = UI.button({
		Text = "✕",
		TextSize = 18,
		BackgroundColor3 = colors.panelLight,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(36, 36),
		Parent = panelBody,
	})
	close.Activated:Connect(closePanel)
	local status = UI.label({
		Text = "",
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = panelBody,
	})
	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
	panelScale.Scale = math.min(1, (viewport.Y - 30) / (height + 24), (viewport.X - 20) / 380)
	panel.Visible = true
	return panelBody, status
end

local function setStatus(label: TextLabel, text: string, good: boolean)
	label.Text = text
	label.TextColor3 = if good then colors.cash else colors.danger
end

local function selectForGamepad(button: GuiObject)
	if UserInputService.GamepadEnabled then
		GuiService.SelectedObject = button
	end
end

---------------------------------------------------------------------------
-- Purchase panel
---------------------------------------------------------------------------
local function openShop(id: string)
	local s = VC.byId[id]
	if not s then
		return
	end
	local body, status = openPanel("Shop", s.name:upper(), s.class:upper() .. "  ·  " .. s.seats .. (if s.seats == 1 then " SEAT" else " SEATS"), 560, VC.LOT_CENTER)
	local paintIndex = s.defaultPaint
	local setLook = preview(body, id, 50, 150)
	setLook(paintIndex, 1, 1)

	UI.label({ Text = UI.formatCash(s.price), Font = UI.FONT_BLACK, TextSize = 26, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 206), Size = UDim2.new(0.5, 0, 0, 30), Parent = body })
	local cashLabel = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 214), Size = UDim2.new(0.5, 0, 0, 16), Parent = body })
	UI.label({ Text = s.blurb, TextSize = 13, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 240), Size = UDim2.new(1, 0, 0, 32), Parent = body })
	local reqLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(0, 274), Size = UDim2.new(1, 0, 0, 16), Parent = body })
	local y = statBars(body, s, 298)

	local paintTitle = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y + 8), Size = UDim2.new(1, 0, 0, 16), Parent = body })
	local swatchRow = row(body, y + 28, 34)
	local buy = UI.button({ Text = "", TextSize = 18, Font = UI.FONT_BLACK, BackgroundColor3 = colors.accent, Position = UDim2.fromOffset(0, y + 74), Size = UDim2.new(1, 0, 0, 46), Parent = body })
	local busy = false

	local swatches: { TextButton } = {}
	local function refresh()
		local owned = ownedVehicles()[id] ~= nil
		local level = player:GetAttribute("Level") or 1
		local rep = player:GetAttribute("Reputation") or 0
		local cash = player:GetAttribute("Cash") or 0
		local unlocked = level >= s.level and rep >= s.rep
		cashLabel.Text = "You have " .. UI.formatCash(cash)
		local req = VC.requirementText(s)
		if req then
			reqLabel.Text = (if unlocked then "✓ Unlocked: " else "🔒 Requires ") .. req .. string.format("  (you: Lv %d, %d rep)", level, rep)
			reqLabel.TextColor3 = if unlocked then colors.cash else colors.stamina
		else
			reqLabel.Text = "No requirements"
			reqLabel.TextColor3 = colors.subtext
		end
		swatchRow.Visible = not owned
		if owned then
			paintTitle.Text = "YOU OWN THIS · RESPRAY IT AT THE PAINT & MODS BAY"
			buy.Text = "SPAWN IT"
			buy.BackgroundColor3 = colors.xp
		else
			paintTitle.Text = "PAINT: " .. VC.PAINTS[paintIndex].name:upper()
			if not unlocked then
				buy.Text = "🔒 LOCKED"
				buy.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
			else
				buy.Text = "BUY  " .. UI.formatCash(s.price)
				buy.BackgroundColor3 = if cash >= s.price then colors.accent else Color3.fromRGB(120, 70, 50)
			end
		end
		for i, b in swatches do
			local stroke = b:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = if i == paintIndex then 0 else 1
			end
		end
	end

	for i, p in VC.PAINTS do
		local b = swatch(swatchRow, p.color, 32, i)
		UI.stroke(Color3.new(1, 1, 1), 3, 1).Parent = b
		b.Activated:Connect(function()
			paintIndex = i
			setLook(paintIndex, 1, 1)
			refresh()
		end)
		swatches[i] = b
	end

	buy.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		if ownedVehicles()[id] then
			local ok, message = remote("VehicleSpawn"):InvokeServer(id)
			setStatus(status, message or "", ok == true)
			if ok then
				closePanel()
			end
		else
			setStatus(status, "Processing...", true)
			local ok, message = remote("VehicleBuy"):InvokeServer(id, paintIndex)
			if ok then
				setStatus(status, "It's yours! Tap SPAWN IT, or use the Garage app on your phone.", true)
			else
				setStatus(status, message or "Purchase failed.", false)
			end
		end
		busy = false
		if panelMode == "Shop" and buy.Parent then
			refresh()
		end
	end)

	local conns = {
		player:GetAttributeChangedSignal("Cash"):Connect(refresh),
		player:GetAttributeChangedSignal("VehiclesOwned"):Connect(refresh),
		player:GetAttributeChangedSignal("Level"):Connect(refresh),
		player:GetAttributeChangedSignal("Reputation"):Connect(refresh),
	}
	table.insert(panelCleanup, function()
		for _, c in conns do
			c:Disconnect()
		end
	end)
	refresh()
	selectForGamepad(buy)
end

---------------------------------------------------------------------------
-- Paint & Mods panel
---------------------------------------------------------------------------
local MOD_ROWS = {
	{ key = "paint", label = "PAINT", list = VC.PAINTS },
	{ key = "rim", label = "RIMS", list = VC.RIMS },
	{ key = "glow", label = "UNDERGLOW", list = VC.GLOWS },
}

local modsSelectedId: string? = nil

local function openMods()
	local list = sortedOwned()
	if #list == 0 then
		local body, _ = openPanel("Mods", "PAINT & MODS", "BUDGET WHEELS", 170, VC.MODS_POS)
		UI.label({ Text = "You don't own a vehicle yet. Pick one from the lot first, then come back to make it yours.", TextSize = 14, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 56), Size = UDim2.new(1, 0, 0, 60), Parent = body })
		return
	end
	if not modsSelectedId or not ownedVehicles()[modsSelectedId] then
		local mine = myVehicle()
		local spawnedId = mine and mine:GetAttribute("VehicleId")
		modsSelectedId = if type(spawnedId) == "string" and ownedVehicles()[spawnedId] then spawnedId else list[1].id
	end
	local id = modsSelectedId :: string
	local s = VC.byId[id]
	local entry = ownedVehicles()[id]
	local body, status = openPanel("Mods", "PAINT & MODS", s.name:upper(), 520, VC.MODS_POS)

	-- vehicle chooser
	local chooser = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 34),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 2,
		Parent = body,
	}, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, item in list do
		local b = UI.button({
			Text = item.name,
			TextSize = 13,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 30),
			BackgroundColor3 = if item.id == id then colors.accent else colors.panelLight,
			LayoutOrder = i,
			Parent = chooser,
		}, { UI.padding(8) })
		b.Activated:Connect(function()
			modsSelectedId = item.id
			openMods()
		end)
	end

	local selection = { paint = entry.paint, rim = entry.rim, glow = entry.glow }
	local setLook = preview(body, id, 90, 140)
	setLook(selection.paint, selection.rim, selection.glow)

	local y = 240
	local busy = false
	for _, def in MOD_ROWS do
		local key = def.key
		local price = VC.MOD_PRICES[key]
		local title = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -110, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = body })
		local apply = UI.button({ Text = "", TextSize = 13, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y - 6), Size = UDim2.fromOffset(104, 28), Parent = body })
		local swatchRow = row(body, y + 20, 34)
		local buttons: { TextButton } = {}
		local function refreshRow()
			local current = entry[key]
			local chosen = selection[key]
			title.Text = string.format("%s · %s  (now: %s)", def.label, UI.formatCash(price), def.list[current] and def.list[current].name or "?")
			if chosen == current then
				apply.Text = "FITTED"
				apply.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
				apply.AutoButtonColor = false
			else
				apply.Text = "APPLY " .. UI.formatCash(price)
				apply.BackgroundColor3 = colors.accent
				apply.AutoButtonColor = true
			end
			for i, b in buttons do
				local stroke = b:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Transparency = if i == chosen then 0 else 1
				end
				b.Text = if i == current then "✓" elseif key == "glow" and i == 1 then "✕" else ""
			end
		end
		for i, option in def.list do
			local b = swatch(swatchRow, option.color, 30, i)
			UI.stroke(Color3.new(1, 1, 1), 3, 1).Parent = b
			b.Activated:Connect(function()
				selection[key] = i
				setLook(selection.paint, selection.rim, selection.glow)
				refreshRow()
				status.Text = def.label .. ": " .. option.name
				status.TextColor3 = colors.text
			end)
			buttons[i] = b
		end
		apply.Activated:Connect(function()
			if busy or selection[key] == entry[key] then
				return
			end
			busy = true
			setStatus(status, "Working on it...", true)
			local ok, message = remote("VehicleMod"):InvokeServer(id, key, selection[key])
			busy = false
			if ok then
				entry[key] = selection[key]
				setStatus(status, def.list[selection[key]].name .. " fitted!", true)
			else
				setStatus(status, message or "Could not apply.", false)
			end
			if apply.Parent then
				refreshRow()
			end
		end)
		refreshRow()
		y += 72
	end
	UI.label({ Text = "Changes are saved and show up on your vehicle right away.", TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 16), Parent = body })
	local first = chooser:FindFirstChildWhichIsA("TextButton")
	if first then
		selectForGamepad(first)
	end
end

---------------------------------------------------------------------------
-- Garage phone app
---------------------------------------------------------------------------
local function buildGarage(content: ScrollingFrame)
	local busy = false
	local function render()
		Phone.clear(content)
		local list = sortedOwned()
		local spawnedId = player:GetAttribute("VehicleSpawned") or ""
		if not player:GetAttribute("DataLoaded") then
			UI.label({ Text = "Loading your garage...", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
			return
		end
		if #list == 0 then
			local c = Phone.card(content, 150, 1)
			UI.label({ Text = "NO VEHICLES YET", Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 20), Parent = c })
			UI.label({ Text = "Budget Wheels sells everything from a $350 bike to supercars. Head over and pick your first ride.", TextSize = 13, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 52), Parent = c })
			local gps = UI.button({ Text = "📍 GPS TO BUDGET WHEELS", TextSize = 13, BackgroundColor3 = colors.xp, Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 36), Parent = c })
			gps.Activated:Connect(function()
				Phone.setGPS("Budget Wheels", VC.LOT_GPS)
			end)
			return
		end
		UI.label({ Text = "YOUR VEHICLES", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = 0, Parent = content })
		local owned = ownedVehicles()
		for i, s in list do
			local isOut = spawnedId == s.id
			local c = Phone.card(content, if isOut then 118 else 84, i)
			local look = owned[s.id]
			local paintColor = (VC.PAINTS[look.paint] or VC.PAINTS[1]).color
			UI.new("Frame", { BackgroundColor3 = paintColor, Size = UDim2.fromOffset(34, 34), Parent = c }, { UI.corner(17), UI.stroke(Color3.new(1, 1, 1), 1.5, 0.5) })
			UI.label({ Text = s.name, Font = UI.FONT_BOLD, TextSize = 15, Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -44, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
			UI.label({
				Text = string.format("%s · %d mph · %d seat%s", s.class, mph(s.topSpeed), s.seats, if s.seats == 1 then "" else "s"),
				TextSize = 12,
				TextColor3 = colors.subtext,
				Position = UDim2.fromOffset(44, 18),
				Size = UDim2.new(1, -44, 0, 16),
				Parent = c,
			})
			local action = UI.button({
				Text = if isOut then "PUT AWAY" else "SPAWN",
				TextSize = 13,
				BackgroundColor3 = if isOut then Color3.fromRGB(150, 60, 60) else colors.accent,
				Position = UDim2.fromOffset(0, 44),
				Size = UDim2.new(1, 0, 0, 30),
				Parent = c,
			})
			action.Activated:Connect(function()
				if busy then
					return
				end
				busy = true
				action.Text = "..."
				if isOut then
					remote("VehicleStore"):InvokeServer()
				else
					remote("VehicleSpawn"):InvokeServer(s.id)
				end
				busy = false
				render()
			end)
			if isOut then
				local locate = UI.button({ Text = "📍 LOCATE", TextSize = 13, BackgroundColor3 = colors.xp, Position = UDim2.fromOffset(0, 78), Size = UDim2.new(1, 0, 0, 28), Parent = c })
				locate.Activated:Connect(function()
					local model = myVehicle()
					if model and model.PrimaryPart then
						Phone.setGPS("My " .. s.name, model.PrimaryPart.Position)
					end
				end)
			end
		end
		local footer = Phone.card(content, 92, #list + 1)
		UI.label({ Text = "Paint, rims & underglow at the Paint & Mods bay. More rides at Budget Wheels.", TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 32), Parent = footer })
		local gps = UI.button({ Text = "📍 GPS TO BUDGET WHEELS", TextSize = 12, BackgroundColor3 = colors.panel, Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 30), Parent = footer })
		gps.Activated:Connect(function()
			Phone.setGPS("Budget Wheels", VC.LOT_GPS)
		end)
	end
	for _, attr in { "VehiclesOwned", "VehicleSpawned", "DataLoaded" } do
		player:GetAttributeChangedSignal(attr):Connect(function()
			Phone.refresh("Garage")
		end)
	end
	return render
end

---------------------------------------------------------------------------
-- Vehicle visuals (all nearby vehicles)
---------------------------------------------------------------------------
type Wheel = { motor: Motor6D, mount: Vector3, steer: boolean, spin: number, drop: number }
type Tracked = {
	model: Model,
	chassis: BasePart,
	seat: VehicleSeat?,
	spec: VC.Spec,
	wheels: { Wheel },
	heads: { BasePart },
	tails: { BasePart },
	lights: { SpotLight },
	drive: ProximityPrompt?,
	ride: ProximityPrompt?,
	params: RaycastParams,
	lightsOn: boolean?,
	tailState: string?,
}

local tracked: { [Model]: Tracked } = {}
local humanoid: Humanoid? = nil

local function updatePrompts()
	local seated = humanoid ~= nil and humanoid.SeatPart ~= nil
	for model, t in tracked do
		if t.drive then
			t.drive.Enabled = not seated and model:GetAttribute("Owner") == player.UserId
		end
		if t.ride then
			t.ride.Enabled = not seated
		end
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or tracked[model] then
		return
	end
	task.spawn(function()
		local chassis = model:WaitForChild("Chassis", 15)
		local s = VC.byId[model:GetAttribute("VehicleId") or ""]
		if not chassis or not chassis:IsA("BasePart") or not s or not model:IsDescendantOf(workspace) then
			return
		end
		-- selene: allow(undefined_variable)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.RespectCanCollide = true
		local t: Tracked = {
			model = model,
			chassis = chassis,
			seat = model:FindFirstChild("DriverSeat") :: VehicleSeat?,
			spec = s,
			wheels = {},
			heads = {},
			tails = {},
			lights = {},
			drive = model:FindFirstChild("DrivePrompt", true) :: ProximityPrompt?,
			ride = model:FindFirstChild("RidePrompt", true) :: ProximityPrompt?,
			params = params,
		}
		local list = characters()
		table.insert(list, model)
		params.FilterDescendantsInstances = list
		for _, d in model:GetDescendants() do
			if d:IsA("Motor6D") and d.Name == "WheelMotor" then
				table.insert(t.wheels, { motor = d, mount = d.C0.Position, steer = d:GetAttribute("Steer") == true, spin = 0, drop = s.travel - s.sag })
			elseif d:IsA("BasePart") and d:GetAttribute("Head") then
				table.insert(t.heads, d)
			elseif d:IsA("BasePart") and d:GetAttribute("Tail") then
				table.insert(t.tails, d)
			elseif d:IsA("SpotLight") then
				table.insert(t.lights, d)
			end
		end
		tracked[model] = t
		updatePrompts()
	end)
end

local function isNight(): boolean
	return Lighting.ClockTime < 6.3 or Lighting.ClockTime > 17.7
end

local driveSim: VC.Sim? = nil
local driveSeat: VehicleSeat? = nil
local driveModel: Model? = nil

local function updateVisuals(dt: number)
	local camera = workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	local night = isNight()
	for model, t in tracked do
		local chassis = t.chassis
		if not chassis.Parent then
			tracked[model] = nil
			continue
		end
		if (chassis.Position - camPos).Magnitude > 260 then
			continue
		end
		local s = t.spec
		local cf = chassis.CFrame
		local up = cf.UpVector
		local vf = chassis.AssemblyLinearVelocity:Dot(cf.LookVector)
		local seat = t.seat
		local steer = 0
		local throttle = 0
		if model == driveModel and driveSim then
			steer = driveSim.steer
			throttle = if driveSeat then driveSeat.ThrottleFloat else 0
		elseif seat and seat.Occupant then
			steer = seat.SteerFloat
			throttle = seat.ThrottleFloat
		end

		-- wheels: suspension drop, steering and spin
		local rest = s.travel - s.sag
		local r = s.wheelRadius
		for _, w in t.wheels do
			local mount = cf:PointToWorldSpace(w.mount + Vector3.new(0, rest, 0))
			local hit = workspace:Raycast(mount, -up * (s.travel + r), t.params)
			local drop = if hit then math.clamp(hit.Distance - r, 0, s.travel) else s.travel
			w.drop += (drop - w.drop) * math.min(1, dt * 25)
			w.spin = (w.spin - vf / r * dt) % (math.pi * 2)
			local steerAngle = if w.steer then -steer * s.steerAngle * 0.8 else 0
			w.motor.Transform = CFrame.new(0, rest - w.drop, 0) * CFrame.Angles(0, steerAngle, 0) * CFrame.Angles(w.spin, 0, 0)
		end

		-- headlights: automatic at night, or forced on by the driver (H)
		local lightsOn = night or model:GetAttribute("Headlights") == true
		if lightsOn ~= t.lightsOn then
			t.lightsOn = lightsOn
			for _, p in t.heads do
				p.Material = if lightsOn then Enum.Material.Neon else Enum.Material.SmoothPlastic
			end
			for _, light in t.lights do
				light.Enabled = lightsOn
			end
		end
		local braking = (throttle < -0.1 and vf > 1) or (throttle > 0.1 and vf < -1)
		local tailState = if braking then "brake" elseif lightsOn then "on" else "off"
		if tailState ~= t.tailState then
			t.tailState = tailState
			for _, p in t.tails do
				p.Material = if tailState == "off" then Enum.Material.SmoothPlastic else Enum.Material.Neon
				p.Color = if tailState == "brake" then Color3.fromRGB(255, 30, 30) elseif tailState == "on" then Color3.fromRGB(170, 20, 20) else Color3.fromRGB(120, 20, 22)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------
local speedo: Frame
local speedLabel: TextLabel
local gearLabel: TextLabel
local nameLabel: TextLabel
local lightsLabel: TextLabel

local function onLightsAction(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		remote("VehicleLights"):FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function stopDriving()
	if driveSim then
		pcall(VC.idle, driveSim)
	end
	driveSim = nil
	driveSeat = nil
	driveModel = nil
	speedo.Visible = false
	ContextActionService:UnbindAction(LIGHTS_ACTION)
end

local function startDriving(model: Model, seat: VehicleSeat)
	local sim = VC.newSim(model)
	if not sim then
		return
	end
	VC.setIgnore(sim, characters())
	driveSim = sim
	driveSeat = seat
	driveModel = model
	nameLabel.Text = sim.spec.name:upper()
	speedo.Visible = true
	ContextActionService:BindAction(LIGHTS_ACTION, onLightsAction, true, Enum.KeyCode.H, Enum.KeyCode.ButtonY)
	ContextActionService:SetTitle(LIGHTS_ACTION, "Lights")
	ContextActionService:SetPosition(LIGHTS_ACTION, UDim2.new(1, -290, 1, -130)) -- clear of the Sprint button
end

-- After getting out, stand next to the vehicle instead of on top of it.
local function placeOutside(seat: BasePart)
	local model = seat.Parent
	local chassis = model and model:IsA("Model") and model.PrimaryPart
	local character = player.Character
	if not chassis or not chassis.Parent or not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - chassis.Position).Magnitude > 25 then
		return
	end
	local cf = chassis.CFrame
	local localSeat = cf:PointToObjectSpace(seat.Position)
	local sides = if localSeat.X > 0.1 then { 1, -1 } else { -1, 1 }
	-- selene: allow(undefined_variable)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = characters()
	table.insert(ignore, model :: Instance)
	rayParams.FilterDescendantsInstances = ignore
	rayParams.RespectCanCollide = true
	-- selene: allow(undefined_variable)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = ignore
	overlap.RespectCanCollide = true
	local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local yaw = if flatLook.Magnitude > 0.1 then CFrame.lookAt(Vector3.zero, flatLook) else CFrame.identity
	local candidates = {}
	for _, side in sides do
		table.insert(candidates, Vector3.new(side * ((chassis :: BasePart).Size.X / 2 + 2.2), 0, localSeat.Z))
	end
	table.insert(candidates, Vector3.new(0, 0, (chassis :: BasePart).Size.Z / 2 + 2.5))
	for _, offset in candidates do
		local spot = cf:PointToWorldSpace(offset)
		local hit = workspace:Raycast(spot + Vector3.new(0, 8, 0), Vector3.new(0, -20, 0), rayParams)
		if hit then
			local stand = hit.Position + Vector3.new(0, 3, 0)
			if #workspace:GetPartBoundsInBox(CFrame.new(stand + Vector3.new(0, 0.3, 0)), Vector3.new(2, 4.4, 2), overlap) == 0 then
				character:PivotTo(yaw + stand)
				return
			end
		end
	end
end

local function hookCharacter(character: Model)
	humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	local hum = humanoid :: Humanoid
	local lastSeat: BasePart? = nil
	hum.Seated:Connect(function(active: boolean, seatPart: BasePart?)
		if active and seatPart then
			lastSeat = seatPart
			local model = seatPart.Parent
			if seatPart:IsA("VehicleSeat") and model and model:IsA("Model") and CollectionService:HasTag(model, TAG) and model:GetAttribute("Owner") == player.UserId then
				startDriving(model, seatPart)
			end
		else
			stopDriving()
			local seat = lastSeat
			lastSeat = nil
			if seat then
				task.delay(0.05, placeOutside, seat)
			end
		end
		updatePrompts()
	end)
	hum.Died:Connect(stopDriving)
	updatePrompts()
end

local function buildSpeedo()
	speedo = UI.new("Frame", {
		Name = "Speedometer",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.12,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -48),
		Size = UDim2.fromOffset(220, 66),
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.padding(8), UI.stroke(colors.accent, 1.5, 0.4) })
	HUD.slot("bottomCenter", speedo, 20)
	nameLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, -60, 0, 12), Parent = speedo })
	speedLabel = UI.label({ Text = "0", Font = UI.FONT_BLACK, TextSize = 34, Position = UDim2.fromOffset(0, 12), Size = UDim2.fromOffset(78, 36), TextXAlignment = Enum.TextXAlignment.Right, Parent = speedo })
	UI.label({ Text = "MPH", Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(82, 28), Size = UDim2.fromOffset(40, 14), Parent = speedo })
	gearLabel = UI.new("TextLabel", {
		Text = "N",
		Font = UI.FONT_BLACK,
		TextSize = 18,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = colors.panelLight,
		Position = UDim2.fromOffset(126, 16),
		Size = UDim2.fromOffset(28, 28),
		Parent = speedo,
	}, { UI.corner(8) })
	lightsLabel = UI.label({ Text = "💡", TextSize = 18, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(158, 16), Size = UDim2.fromOffset(28, 28), Parent = speedo })
	local exit = UI.button({
		Text = "EXIT",
		TextSize = 11,
		BackgroundColor3 = Color3.fromRGB(150, 60, 60),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, -2),
		Size = UDim2.fromOffset(44, 22),
		Parent = speedo,
	})
	exit.Activated:Connect(function()
		if humanoid and humanoid.SeatPart then
			humanoid.Jump = true
		end
	end)
	if UserInputService.KeyboardEnabled then
		UI.label({
			Text = "WASD drive · H lights · Space exit",
			TextSize = 11,
			TextColor3 = colors.subtext,
			TextXAlignment = Enum.TextXAlignment.Center,
			-- above the panel: the HUD stacks other chips right below it
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0, -12),
			Size = UDim2.new(1, 40, 0, 12),
			TextStrokeTransparency = 0.6,
			Parent = speedo,
		})
	end

	RunService.RenderStepped:Connect(function()
		local model = driveModel
		local seat = driveSeat
		if not speedo.Visible or not model or not seat then
			return
		end
		local chassis = model.PrimaryPart
		if not chassis then
			return
		end
		local vf = chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector)
		speedLabel.Text = tostring(mph(vf))
		local throttle = seat.ThrottleFloat
		gearLabel.Text = if vf < -1 or (throttle < -0.1 and vf < 1) then "R" elseif math.abs(vf) < 0.5 and math.abs(throttle) < 0.1 then "N" else "D"
		gearLabel.BackgroundColor3 = if gearLabel.Text == "R" then colors.danger elseif gearLabel.Text == "D" then Color3.fromRGB(40, 140, 70) else colors.panelLight
		local on = isNight() or model:GetAttribute("Headlights") == true
		lightsLabel.TextTransparency = if on then 0 else 0.7
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Vehicles.start()
	Phone.addApp({ id = "Garage", label = "Garage", icon = "🚗", color = Color3.fromRGB(40, 140, 220) }, buildGarage)

	gui = UI.new("ScreenGui", {
		Name = "CityGrindVehicles",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 6,
		Parent = player:WaitForChild("PlayerGui"),
	})
	panel = UI.new("Frame", {
		Name = "VehiclePanel",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(380, 560),
		Visible = false,
		Parent = gui,
	}, { UI.corner(18), UI.padding(12), UI.stroke(colors.accent, 1.5, 0.3) })
	panelScale = UI.new("UIScale", { Parent = panel })
	buildSpeedo()

	task.spawn(function()
		remote("VehicleUI").OnClientEvent:Connect(function(mode: any, id: any)
			if mode == "Shop" and type(id) == "string" then
				openShop(id)
			elseif mode == "Mods" then
				openMods()
			end
		end)
	end)

	-- close the panel when walking away
	task.spawn(function()
		while true do
			task.wait(0.5)
			if panel.Visible and panelAnchor then
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				local range = if panelMode == "Mods" then VC.MODS_RANGE else VC.SHOP_RANGE
				if not root or (root.Position - panelAnchor).Magnitude > range then
					closePanel()
				end
			end
		end
	end)

	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
		if model:IsA("Model") then
			tracked[model] = nil
		end
	end)
	for _, model in CollectionService:GetTagged(TAG) do
		track(model)
	end

	-- keep raycasts from hitting characters
	task.spawn(function()
		while true do
			task.wait(1)
			local list = characters()
			for model, t in tracked do
				local filter = table.clone(list)
				table.insert(filter, model)
				t.params.FilterDescendantsInstances = filter
			end
			if driveSim then
				VC.setIgnore(driveSim, list)
			end
		end
	end)

	RunService.PreSimulation:Connect(function(dt: number)
		local sim, seat = driveSim, driveSeat
		if sim and seat then
			if seat.Parent and humanoid and humanoid.SeatPart == seat and sim.chassis.Parent then
				VC.step(sim, dt, seat.ThrottleFloat, seat.SteerFloat, true)
			else
				stopDriving()
			end
		end
		updateVisuals(dt)
	end)

	player.CharacterAdded:Connect(function(character)
		stopDriving()
		task.spawn(hookCharacter, character)
	end)
	if player.Character then
		task.spawn(hookCharacter, player.Character)
	end
end

return Vehicles
