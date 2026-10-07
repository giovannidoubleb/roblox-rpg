-- CITY GRIND: subway client (section 11).
-- The server opens the station picker when you use a "Take Subway" prompt
-- (SubwayUI "Open", stationId). Picking a stop calls SubwayRide(destId); the
-- server checks distance, cooldown, state and charges the fare, then teleports
-- you while this screen shows the fade-to-black ride. Nothing here moves the
-- player or touches money.
-- Also adds a "Subway" phone app: the line map with GPS to every entrance.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local DC = require(shared:WaitForChild("DistrictsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Subway = {}

local gui: ScreenGui
local panel: Frame
local titleLabel: TextLabel
local fareLabel: TextLabel
local statusLabel: TextLabel
local list: Frame
local overlay: Frame
local overlayTitle: TextLabel
local overlaySub: TextLabel
local trainBar: Frame

local rideRemote: RemoteFunction? = nil
local fromStation: string? = nil
local busy = false

---------------------------------------------------------------------------
-- Ride (fade to black while the server moves you)
---------------------------------------------------------------------------
local function fade(target: number, time: number)
	local tween = TweenService:Create(overlay, TweenInfo.new(time, Enum.EasingStyle.Quad), { BackgroundTransparency = target })
	tween:Play()
	tween.Completed:Wait()
end

local function closePicker()
	panel.Visible = false
	fromStation = nil
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
end

local function ride(dest: DC.Station)
	if busy or not rideRemote then
		return
	end
	busy = true
	statusLabel.Text = "Buying a ticket…"
	statusLabel.TextColor3 = colors.subtext
	local remote = rideRemote :: RemoteFunction
	local ok, success, result = pcall(function()
		return remote:InvokeServer(dest.id)
	end)
	if not ok or not success then
		statusLabel.Text = if ok and type(result) == "string" then result else "The subway is busy. Try again."
		statusLabel.TextColor3 = colors.danger
		busy = false
		return
	end
	local rideTime = if type(result) == "number" then result else DC.SUBWAY_RIDE_TIME
	closePicker()

	-- the trip: fade out, a train rushing past, fade back in at the new station
	overlay.Visible = true
	overlay.BackgroundTransparency = 1
	overlayTitle.Text = "NEXT STOP: " .. string.upper(dest.name)
	overlaySub.Text = string.format("Fare paid $%d · stand clear of the closing doors", DC.SUBWAY_FARE)
	trainBar.BackgroundColor3 = dest.line
	overlayTitle.Visible = true
	overlaySub.Visible = true
	trainBar.Visible = true
	local start = os.clock()
	local conn = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) * 1.6 % 1
		trainBar.Position = UDim2.fromScale(-0.6 + t * 1.6, 0.62)
	end)
	fade(0, math.min(0.4, rideTime * 0.2))
	task.wait(math.max(0.2, rideTime - 0.8))
	conn:Disconnect()
	overlayTitle.Visible = false
	overlaySub.Visible = false
	trainBar.Visible = false
	fade(1, 0.4)
	overlay.Visible = false
	HUD.push("SUBWAY", "Welcome to " .. DC.displayName(dest.id) .. ".")
	busy = false
end

---------------------------------------------------------------------------
-- Station picker
---------------------------------------------------------------------------
local function openPicker(stationId: string)
	local here = DC.station(stationId)
	if not here or busy then
		return
	end
	fromStation = stationId
	titleLabel.Text = "SUBWAY · " .. string.upper(here.name)
	local cash = player:GetAttribute("Cash")
	fareLabel.Text = string.format("Fare $%d per ride  ·  You have %s", DC.SUBWAY_FARE, UI.formatCash(if type(cash) == "number" then cash else 0))
	statusLabel.Text = "Pick your stop."
	statusLabel.TextColor3 = colors.subtext
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local first: GuiObject? = nil
	for i, st in DC.STATIONS do
		if st.id ~= stationId then
			local row = UI.new("Frame", { BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, 0, 0, 48), LayoutOrder = i, Parent = list }, { UI.corner(10) })
			UI.new("Frame", { BackgroundColor3 = st.line, Position = UDim2.fromOffset(10, 12), Size = UDim2.fromOffset(24, 24), Parent = row }, { UI.corner(12) })
			UI.label({ Text = st.name, Font = UI.FONT_BOLD, TextSize = 16, Position = UDim2.fromOffset(44, 6), Size = UDim2.new(1, -140, 0, 20), Parent = row })
			local dist = math.floor((Vector3.new(st.entrance.X, 0, st.entrance.Z) - Vector3.new(here.entrance.X, 0, here.entrance.Z)).Magnitude / 3.57)
			UI.label({ Text = DC.displayName(st.id) .. "  ·  " .. dist .. "m away", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(44, 26), Size = UDim2.new(1, -140, 0, 16), Parent = row })
			local go = UI.button({ Text = "RIDE $" .. DC.SUBWAY_FARE, TextSize = 14, BackgroundColor3 = st.line, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(84, 34), Parent = row })
			go.Activated:Connect(function()
				task.spawn(ride, st)
			end)
			first = first or go
		end
	end
	panel.Visible = true
	if first and GuiService:IsTenFootInterface() then
		GuiService.SelectedObject = first
	end
end

local function buildGui()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindSubway",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 6,
		Parent = player:WaitForChild("PlayerGui"),
	})
	panel = UI.new("Frame", {
		Name = "Picker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 340, 0.85, 0),
		BackgroundColor3 = colors.panel,
		Visible = false,
		Parent = gui,
	}, { UI.corner(16), UI.padding(14), UI.stroke(Color3.fromRGB(60, 60, 80), 1.5), UI.new("UISizeConstraint", { MaxSize = Vector2.new(340, 430) }) })
	titleLabel = UI.label({ Text = "SUBWAY", Font = UI.FONT_BLACK, TextSize = 20, Size = UDim2.new(1, -40, 0, 26), Parent = panel })
	local close = UI.button({ Text = "✕", TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, -2), Size = UDim2.fromOffset(32, 30), BackgroundColor3 = colors.panelLight, Parent = panel })
	close.Activated:Connect(closePicker)
	fareLabel = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 18), Parent = panel })
	list = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 54),
		Size = UDim2.new(1, 0, 1, -84),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		Parent = panel,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	statusLabel = UI.label({ Text = "", TextSize = 13, TextWrapped = true, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 26), Parent = panel })

	overlay = UI.new("Frame", { Name = "Ride", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 20, Parent = gui })
	overlayTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 30, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.new(1, -40, 0, 40), ZIndex = 21, Visible = false, Parent = overlay })
	overlaySub = UI.label({ Text = "", TextSize = 15, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.new(1, -40, 0, 24), ZIndex = 21, Visible = false, Parent = overlay })
	trainBar = UI.new("Frame", { Size = UDim2.new(0.6, 0, 0, 10), Position = UDim2.fromScale(-0.6, 0.62), ZIndex = 21, Visible = false, Parent = overlay }, { UI.corner(5) })
end

---------------------------------------------------------------------------
-- Phone app: the line and GPS to each entrance
---------------------------------------------------------------------------
local function buildApp(content: ScrollingFrame): () -> ()
	return function()
		Phone.clear(content)
		local intro = Phone.card(content, 64, 1)
		UI.label({ Text = "CITY SUBWAY", Font = UI.FONT_BLACK, TextSize = 15, Size = UDim2.new(1, 0, 0, 18), Parent = intro })
		UI.label({ Text = string.format("$%d to any district. Walk up to an entrance and use Take Subway.", DC.SUBWAY_FARE), TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 30), Parent = intro })
		local rides = player:GetAttribute("SubwayRides")
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		for i, st in DC.STATIONS do
			local row = Phone.card(content, 50, 1 + i)
			UI.new("Frame", { BackgroundColor3 = st.line, Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(18, 18), Parent = row }, { UI.corner(9) })
			UI.label({ Text = st.name, Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -96, 0, 16), Parent = row })
			local dist = if root then math.floor((root.Position - st.entrance).Magnitude / 3.57) .. "m" else ""
			UI.label({ Text = DC.displayName(st.id) .. "  ·  " .. dist, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(26, 16), Size = UDim2.new(1, -96, 0, 14), Parent = row })
			local go = UI.button({ Text = "GPS", TextSize = 13, BackgroundColor3 = Color3.fromRGB(40, 120, 220), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(56, 28), Parent = row })
			go.Activated:Connect(function()
				Phone.setGPS("Subway · " .. st.name, st.entrance)
			end)
		end
		local stats = Phone.card(content, 30, 10)
		UI.label({ Text = string.format("Rides taken this session: %d", if type(rides) == "number" then rides else 0), TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1), Parent = stats })
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Subway.start()
	Phone.addApp({ id = "Subway", label = "Subway", icon = "🚇", color = Color3.fromRGB(40, 120, 230) }, buildApp)
	task.spawn(function()
		buildGui()
		local remotes = shared:WaitForChild("Remotes")
		local uiRemote = remotes:WaitForChild("SubwayUI") :: RemoteEvent
		rideRemote = remotes:WaitForChild("SubwayRide") :: RemoteFunction
		uiRemote.OnClientEvent:Connect(function(kind: any, stationId: any)
			if kind == "Open" and type(stationId) == "string" then
				openPicker(stationId)
			end
		end)
		-- walking away from the entrance closes the picker
		while true do
			task.wait(0.5)
			if panel.Visible and fromStation and not busy then
				local st = DC.station(fromStation)
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not st or not root or (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(st.entrance.X, 0, st.entrance.Z)).Magnitude > DC.SUBWAY_RANGE + 6 then
					closePicker()
				end
			end
		end
	end)
end

return Subway
