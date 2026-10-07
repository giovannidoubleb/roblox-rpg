-- CITY GRIND: racing on the client (spec sections 58, 62, 98).
-- * RACE HQ panel (opened by the kiosk prompt at the City Speedway start line):
--   circuit race lobby (join / leave) and time trial start.
-- * Race HUD: position, lap, timer, best lap, mini standings, "Wet track" when
--   the weather lowers grip, quit button; big countdown; banners for laps and
--   missed checkpoints; next-checkpoint highlight arch (local only) and an
--   on-screen arrow with the distance to it.
-- * Results screen, street race challenges (player menu action
--   "Challenge to race" + route picker, incoming challenge with a 15 s window).
-- * Phone app "Racing": best times, medals, stats, street routes with GPS,
--   recent results, time trial start / GPS to the speedway.
-- The server validates everything (server/Racing).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent:WaitForChild("UI"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local RC = require(shared:WaitForChild("RacingConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Racing = {}

local APP_ID = "Racing"
local APP_COLOR = Color3.fromRGB(220, 50, 60)
local METERS_PER_STUD = 0.49 -- matches the speedometer (1.1 mph per stud/s)

local remotes: Instance? = nil
local gui: ScreenGui

type Setup = { id: string, kind: string, name: string, laps: number, cps: { { p: Vector3, g: Vector3, f: Vector3, w: number } }, goT: number, total: number }
local current: Setup? = nil
local state: { [string]: any }? = nil
local outOfRace = false
local finishedTime: number? = nil
local highlight: Model? = nil
local highlightKey = ""
local goShownUntil = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function invoke(action: string, a: any?, b: any?): (boolean, string, any)
	if not remotes then
		return false, "Still connecting...", nil
	end
	local rf = (remotes :: Instance):FindFirstChild("RacingAction")
	if not rf or not rf:IsA("RemoteFunction") then
		return false, "Racing isn't available.", nil
	end
	local ok, success, message, data = pcall(function()
		return rf:InvokeServer(action, a, b)
	end)
	if not ok then
		return false, "Connection problem. Try again.", nil
	end
	return success == true, if type(message) == "string" then message else "", data
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function isDriving(p: Player): boolean
	local d = p:GetAttribute("Driving")
	return type(d) == "string" and d ~= ""
end

local function distanceText(studs: number): string
	local m = studs * METERS_PER_STUD
	if m >= 1000 then
		return string.format("%.1f km", m / 1000)
	end
	return string.format("%d m", math.floor(m + 0.5))
end

local function isWet(): boolean
	local grip = workspace:GetAttribute("WeatherGrip")
	return type(grip) == "number" and grip < 0.999
end

local function selectForGamepad(button: GuiObject?)
	if button and UserInputService.GamepadEnabled then
		GuiService.SelectedObject = button
	end
end

local function rewardText(reward: any): string
	if type(reward) ~= "table" then
		return ""
	end
	local parts = {}
	if (reward.cash or 0) > 0 then
		table.insert(parts, "+" .. UI.formatCash(reward.cash))
	end
	if (reward.xp or 0) > 0 then
		table.insert(parts, "+" .. reward.xp .. " XP")
	end
	if (reward.rep or 0) > 0 then
		table.insert(parts, "+" .. reward.rep .. " rep")
	end
	return table.concat(parts, "  ·  ")
end

local function modal(name: string, width: number, height: number, accent: Color3): Frame
	local frame = UI.new("Frame", {
		Name = name,
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.03,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	}, { UI.corner(18), UI.padding(14), UI.stroke(accent, 1.5, 0.3) })
	local scale = UI.new("UIScale", { Parent = frame })
	local function fit()
		local camera = workspace.CurrentCamera
		local vp = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		scale.Scale = math.min(1, (vp.Y - 20) / height, (vp.X - 20) / width)
	end
	fit()
	frame:GetPropertyChangedSignal("Visible"):Connect(fit)
	return frame
end

local function clearChildren(frame: Instance)
	for _, c in frame:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function closeButton(parent: Frame, onClose: () -> ())
	local close = UI.button({
		Text = "✕",
		TextSize = 18,
		BackgroundColor3 = colors.panelLight,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(34, 34),
		Parent = parent,
	})
	close.Activated:Connect(onClose)
end

---------------------------------------------------------------------------
-- Race HUD
---------------------------------------------------------------------------
local hud: Frame
local hudTitle: TextLabel
local posLabel: TextLabel
local lapLabel: TextLabel
local timeLabel: TextLabel
local bestLabel: TextLabel
local wetLabel: TextLabel
local board: Frame
local quitButton: TextButton
local lobbyChip: TextLabel
local countdownLabel: TextLabel
local banner: TextLabel
local arrowFrame: Frame
local arrow: TextLabel
local arrowText: TextLabel
local bannerToken = 0
local quitArmed = 0
local lobbyState: { [string]: any }? = nil

local function showBanner(text: string, color: Color3, seconds: number)
	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	banner.TextColor3 = color
	banner.Visible = true
	task.delay(seconds, function()
		if bannerToken == token then
			banner.Visible = false
		end
	end)
end

local function clearHighlight()
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	highlightKey = ""
end

local function updateHighlight()
	local setup = current
	local s = state
	if not setup or outOfRace or finishedTime or not s then
		clearHighlight()
		return
	end
	local index = s.next
	local key = setup.id .. ":" .. tostring(index) .. ":" .. tostring(s.lap)
	if key == highlightKey then
		return
	end
	clearHighlight()
	local cp = setup.cps[index]
	if not cp then
		return
	end
	highlightKey = key
	local last = index == #setup.cps
	local finalLap = last and (s.lap or 1) >= (setup.laps or 1)
	local color = if finalLap then Color3.fromRGB(255, 255, 255) elseif last then Color3.fromRGB(255, 220, 60) else Color3.fromRGB(60, 230, 255)
	highlight = RC.buildArch(cp.g, cp.f, math.min(cp.w, 18) + 1.5, color, 0.15, workspace)
end

local function renderBoard()
	clearChildren(board)
	local s = state
	if not s or type(s.board) ~= "table" then
		return
	end
	for i, row in s.board do
		if i > RC.MAX_RACERS then
			break
		end
		local me = row.u == player.UserId
		local text = string.format("%d. %s", i, tostring(row.n))
		if row.s == "fin" then
			text ..= "  " .. RC.formatTime(row.t)
		elseif row.s == "dnf" then
			text ..= "  DNF"
		end
		UI.label({
			Text = text,
			Font = if me then UI.FONT_BLACK else UI.FONT,
			TextSize = 12,
			TextColor3 = if me then colors.stamina elseif row.s == "dnf" then colors.subtext else colors.text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 15),
			LayoutOrder = i,
			Parent = board,
		})
	end
end

local function refreshHud()
	local setup = current
	local s = state
	if not setup or outOfRace then
		hud.Visible = false
		return
	end
	hud.Visible = true
	hudTitle.Text = setup.name:upper()
	if s then
		posLabel.Text = if setup.kind == "trial" then "SOLO" else string.format("P%d/%d", s.pos or 1, s.total or setup.total)
		lapLabel.Text = if (setup.laps or 1) > 1 then string.format("LAP %d/%d", s.lap or 1, setup.laps) else string.format("CP %d/%d", math.min(s.next or 1, #setup.cps), #setup.cps)
		bestLabel.Text = if (s.bestLap or 0) > 0 then "BEST LAP " .. RC.formatTime(s.bestLap) else ""
	end
	renderBoard()
end

local function onRace(setup: any)
	if type(setup) ~= "table" or type(setup.cps) ~= "table" then
		return
	end
	current = setup :: Setup
	state = nil
	outOfRace = false
	finishedTime = nil
	quitArmed = 0
	quitButton.Text = if setup.kind == "trial" then "ABANDON" else "QUIT"
	clearHighlight()
	refreshHud()
	if setup.kind == "street" then
		HUD.push("STREET RACE", setup.name .. " — follow the arches. Go on green!")
	end
end

local function onState(s: any)
	if type(s) ~= "table" or not current or s.id ~= (current :: Setup).id then
		return
	end
	state = s
	if s.finished and not finishedTime then
		finishedTime = s.time
	end
	refreshHud()
	updateHighlight()
end

local function buildHud()
	hud = UI.new("Frame", {
		Name = "RaceHud",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.12,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.46, 0),
		Size = UDim2.fromOffset(200, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = gui,
	}, {
		UI.corner(14),
		UI.padding(10),
		UI.stroke(Color3.fromRGB(220, 50, 60), 1.5, 0.3),
		UI.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }),
	})
	HUD.slot("left", hud, 10)
	hudTitle = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = colors.subtext, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 13), LayoutOrder = 1, Parent = hud })
	local top = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 2, Parent = hud })
	posLabel = UI.label({ Text = "P1/1", Font = UI.FONT_BLACK, TextSize = 30, Size = UDim2.new(0.55, 0, 1, 0), Parent = top })
	lapLabel = UI.label({ Text = "LAP 1/3", Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.45, 0, 1, 0), Parent = top })
	timeLabel = UI.label({ Text = "0:00.00", Font = UI.FONT_BLACK, TextSize = 22, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 3, Parent = hud })
	bestLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = colors.cash, Size = UDim2.new(1, 0, 0, 13), LayoutOrder = 4, Parent = hud })
	wetLabel = UI.label({ Text = "🌧 WET TRACK · less grip", Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = colors.xp, Size = UDim2.new(1, 0, 0, 13), Visible = false, LayoutOrder = 5, Parent = hud })
	board = UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 6,
		Parent = hud,
	}, { UI.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }) })
	quitButton = UI.button({ Text = "QUIT", TextSize = 12, BackgroundColor3 = Color3.fromRGB(150, 60, 60), Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 7, Parent = hud })
	quitButton.Activated:Connect(function()
		if os.clock() > quitArmed then
			quitArmed = os.clock() + 3
			quitButton.Text = "TAP AGAIN TO QUIT"
			task.delay(3, function()
				if os.clock() >= quitArmed and quitButton.Parent then
					quitButton.Text = if current and (current :: Setup).kind == "trial" then "ABANDON" else "QUIT"
				end
			end)
			return
		end
		quitArmed = 0
		local _, message = invoke("quit")
		if message ~= "" then
			HUD.push("RACE", message)
		end
	end)

	lobbyChip = UI.label({
		Text = "",
		Font = UI.FONT_BOLD,
		TextSize = 13,
		TextWrapped = true,
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.12,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.46, 0),
		Size = UDim2.fromOffset(200, 54),
		Visible = false,
		Parent = gui,
	}, { UI.corner(12), UI.padding(8), UI.stroke(colors.stamina, 1.5, 0.4) })
	HUD.slot("left", lobbyChip, 11)

	countdownLabel = UI.label({
		Text = "",
		Font = UI.FONT_BLACK,
		TextSize = 110,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.3,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(400, 130),
		Visible = false,
		Parent = gui,
	})
	banner = UI.label({
		Text = "",
		Font = UI.FONT_BLACK,
		TextSize = 26,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.35,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.26),
		Size = UDim2.new(0.8, 0, 0, 64),
		Visible = false,
		Parent = gui,
	})
	arrowFrame = UI.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 128),
		Size = UDim2.fromOffset(140, 70),
		Visible = false,
		Parent = gui,
	})
	arrow = UI.label({
		Text = "▲",
		Font = UI.FONT_BLACK,
		TextSize = 40,
		TextColor3 = Color3.fromRGB(60, 230, 255),
		TextStrokeTransparency = 0.3,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(46, 46),
		Parent = arrowFrame,
	})
	arrowText = UI.label({
		Text = "",
		Font = UI.FONT_BOLD,
		TextSize = 13,
		TextStrokeTransparency = 0.4,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = arrowFrame,
	})
end

local function updateFrame()
	local setup = current
	local t = now()
	-- countdown / GO
	if setup and not outOfRace and t < setup.goT then
		countdownLabel.Visible = true
		countdownLabel.Text = tostring(math.ceil(setup.goT - t))
		countdownLabel.TextColor3 = colors.stamina
		goShownUntil = setup.goT + 1
	elseif setup and t < goShownUntil then
		countdownLabel.Visible = true
		countdownLabel.Text = "GO!"
		countdownLabel.TextColor3 = colors.cash
	else
		countdownLabel.Visible = false
	end
	-- lobby chip (only while queued, not racing)
	local lobbyInfo = lobbyState
	if not setup and lobbyInfo and lobbyInfo.inLobby then
		lobbyChip.Visible = true
		local status
		if lobbyInfo.raceLive then
			status = "Race on track, you're next"
		elseif lobbyInfo.startAt then
			status = string.format("Grid in %ds", math.max(0, math.ceil(lobbyInfo.startAt - t)))
		else
			status = "Waiting for racers"
		end
		lobbyChip.Text = string.format("🏁 RACE LOBBY %d/%d\n%s", lobbyInfo.count or 0, lobbyInfo.max or RC.MAX_RACERS, status)
	else
		lobbyChip.Visible = false
	end
	if not setup or outOfRace then
		arrowFrame.Visible = false
		return
	end
	wetLabel.Visible = isWet()
	-- timer
	local elapsed = if finishedTime then finishedTime else math.max(0, t - setup.goT)
	timeLabel.Text = RC.formatTime(math.max(elapsed, 0.001))
	if finishedTime then
		timeLabel.TextColor3 = colors.cash
	else
		timeLabel.TextColor3 = colors.text
	end
	-- arrow to the next checkpoint
	local s = state
	local cp = s and setup.cps[s.next or 1]
	local camera = workspace.CurrentCamera
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if cp and camera and rootPart and not finishedTime then
		arrowFrame.Visible = true
		local to = cp.p - camera.CFrame.Position
		local look = camera.CFrame.LookVector
		local right = camera.CFrame.RightVector
		local angle = math.atan2(to.X * right.X + to.Z * right.Z, to.X * look.X + to.Z * look.Z)
		arrow.Rotation = math.deg(angle)
		local d = Vector3.new(cp.p.X - rootPart.Position.X, 0, cp.p.Z - rootPart.Position.Z).Magnitude
		local last = (s :: any).next == #setup.cps
		arrowText.Text = (if last and ((s :: any).lap or 1) >= setup.laps then "FINISH" elseif last then "LINE" else "CP " .. tostring((s :: any).next)) .. " · " .. distanceText(d)
	else
		arrowFrame.Visible = false
	end
end

---------------------------------------------------------------------------
-- RACE HQ panel
---------------------------------------------------------------------------
local panel: Frame
local panelInfo: { [string]: any }? = nil
local panelStatus: TextLabel? = nil
local panelLobbyText: TextLabel? = nil
local panelNames: TextLabel? = nil
local panelJoin: TextButton? = nil

local function setPanelStatus(text: string, good: boolean)
	if panelStatus then
		panelStatus.Text = text
		panelStatus.TextColor3 = if good then colors.cash else colors.danger
	end
end

local function refreshPanelLobby()
	local info = panelInfo
	local l = lobbyState or (info and info.lobby)
	if not l or not panelLobbyText or not panelNames or not panelJoin then
		return
	end
	local status
	if l.raceLive then
		status = string.format("Race in progress (%d racers). The lobby fills the next grid.", l.raceCount or 0)
	elseif l.startAt then
		status = string.format("Grid forms in %ds", math.max(0, math.ceil(l.startAt - now())))
	elseif (l.count or 0) < (l.min or 2) then
		status = string.format("Waiting for racers: %d/%d (need %d)", l.count or 0, l.max or 8, l.min or 2)
	else
		status = "Starting soon"
	end
	panelLobbyText.Text = status
	panelNames.Text = if #(l.names or {}) > 0 then table.concat(l.names, ", ") else "Nobody yet. Be the first!"
	local joined = l.inLobby == true
	panelJoin.Text = if joined then "LEAVE LOBBY" else "JOIN RACE"
	panelJoin.BackgroundColor3 = if joined then Color3.fromRGB(150, 60, 60) else colors.accent
end

local function closePanel()
	panel.Visible = false
	panelInfo = nil
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
end

local function openPanel(info: any)
	if type(info) ~= "table" then
		return
	end
	panelInfo = info
	lobbyState = info.lobby or lobbyState
	clearChildren(panel)
	UI.label({ Text = "RACE HQ", Font = UI.FONT_BLACK, TextSize = 22, Size = UDim2.new(1, -44, 0, 26), Parent = panel })
	UI.label({ Text = string.format("%s · %d LAPS", RC.TRACK_NAME:upper(), RC.LAPS), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = APP_COLOR, Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, -44, 0, 16), Parent = panel })
	closeButton(panel, closePanel)

	-- circuit race lobby
	local lobbyCard = UI.new("Frame", { BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(0, 52), Size = UDim2.new(1, 0, 0, 150), Parent = panel }, { UI.corner(12), UI.padding(10) })
	UI.label({ Text = "CIRCUIT RACE · 2-8 DRIVERS", Font = UI.FONT_BLACK, TextSize = 13, Size = UDim2.new(1, 0, 0, 16), Parent = lobbyCard })
	panelLobbyText = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.stamina, TextWrapped = true, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 32), Parent = lobbyCard })
	panelNames = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 36), Parent = lobbyCard })
	panelJoin = UI.button({ Text = "JOIN RACE", TextSize = 15, Font = UI.FONT_BLACK, BackgroundColor3 = colors.accent, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 38), Parent = lobbyCard })
	local busy = false
	;(panelJoin :: TextButton).Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		local l = lobbyState
		local leaving = l ~= nil and l.inLobby == true
		local ok, message = invoke(if leaving then "leave" else "join")
		setPanelStatus(message, ok)
		busy = false
	end)

	-- time trial
	local stats = info.stats or {}
	local trialCard = UI.new("Frame", { BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(0, 212), Size = UDim2.new(1, 0, 0, 128), Parent = panel }, { UI.corner(12), UI.padding(10) })
	UI.label({ Text = "TIME TRIAL · SOLO", Font = UI.FONT_BLACK, TextSize = 13, Size = UDim2.new(1, 0, 0, 16), Parent = trialCard })
	local medal = RC.medalInfo(stats.medal or 0)
	UI.label({
		Text = string.format("Your best: %s%s", RC.formatTime(stats.bestRace), if medal then "   " .. medal.icon .. " " .. medal.name else ""),
		TextSize = 13,
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = trialCard,
	})
	local medalLine = {}
	for _, m in RC.MEDALS do
		table.insert(medalLine, m.icon .. " " .. RC.formatTime(m.time))
	end
	UI.label({ Text = table.concat(medalLine, "   "), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 16), Parent = trialCard })
	local trialButton = UI.button({ Text = "START TIME TRIAL", TextSize = 15, Font = UI.FONT_BLACK, BackgroundColor3 = colors.xp, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 38), Parent = trialCard })
	trialButton.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		local ok, message = invoke("trial")
		setPanelStatus(message, ok)
		busy = false
		if ok then
			closePanel()
		end
	end)

	panelStatus = UI.label({ Text = if isDriving(player) then "" else "Get in your car to race.", TextSize = 13, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = colors.stamina, Position = UDim2.fromOffset(0, 342), Size = UDim2.new(1, 0, 0, 30), Parent = panel })
	panel.Visible = true
	refreshPanelLobby()
	selectForGamepad(panelJoin)
end

---------------------------------------------------------------------------
-- Results screen
---------------------------------------------------------------------------
local results: Frame

local function closeResults()
	results.Visible = false
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(results) then
		GuiService.SelectedObject = nil
	end
end

local function showResults(data: any)
	if type(data) ~= "table" or type(data.rows) ~= "table" then
		return
	end
	if current and (current :: Setup).id == data.id then
		current = nil
		state = nil
		outOfRace = false
		finishedTime = nil
		clearHighlight()
		refreshHud()
	end
	clearChildren(results)
	local you = data.you or {}
	local title = if data.kind == "trial" then "TIME TRIAL" elseif data.kind == "street" then "STREET RACE" else "RACE RESULTS"
	UI.label({ Text = title, Font = UI.FONT_BLACK, TextSize = 22, Size = UDim2.new(1, -44, 0, 26), Parent = results })
	UI.label({ Text = tostring(data.name or ""):upper() .. (if (data.laps or 1) > 1 then " · " .. data.laps .. " LAPS" else ""), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = APP_COLOR, Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, -44, 0, 16), Parent = results })
	closeButton(results, closeResults)

	local headline, color
	if you.finished then
		headline = (if data.kind == "trial" then "" else RC.ordinal(you.place or 0) .. "  ·  ") .. RC.formatTime(you.time)
		color = if (you.place or 0) == 1 and data.kind ~= "trial" then Color3.fromRGB(255, 215, 60) else colors.text
	else
		headline = "DNF"
		color = colors.danger
	end
	UI.label({ Text = headline, Font = UI.FONT_BLACK, TextSize = 30, TextColor3 = color, Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 34), Parent = results })
	local lines = {}
	if not you.finished and you.reason then
		table.insert(lines, tostring(you.reason))
	end
	local reward = you.reward
	if type(reward) == "table" then
		local m = RC.medalInfo(reward.medal or 0)
		if m then
			table.insert(lines, m.icon .. " " .. m.name:upper() .. " MEDAL" .. (if reward.newMedal then "  (NEW!)" else ""))
		elseif data.kind == "trial" and you.finished then
			local bronze = RC.medalInfo(1)
			if bronze then
				table.insert(lines, "No medal. Bronze is under " .. RC.formatTime(bronze.time) .. ".")
			end
		end
		if reward.newBest then
			table.insert(lines, "🔥 NEW PERSONAL BEST")
		end
		local rt = rewardText(reward)
		if rt ~= "" then
			table.insert(lines, rt)
		end
		if reward.capped then
			table.insert(lines, "Reward limit reached for this hour: XP only.")
		end
	end
	if (you.bestLap or 0) > 0 then
		table.insert(lines, "Best lap " .. RC.formatTime(you.bestLap))
	end
	if data.note and data.note ~= "" and you.finished then
		table.insert(lines, tostring(data.note))
	end
	UI.label({ Text = table.concat(lines, "\n"), TextSize = 13, TextColor3 = colors.cash, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 86), Size = UDim2.new(1, 0, 0, 84), Parent = results })

	if data.kind ~= "trial" then
		local list = UI.new("Frame", { BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(0, 176), Size = UDim2.new(1, 0, 0, 170), Parent = results }, {
			UI.corner(12),
			UI.padding(8),
			UI.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }),
		})
		for i, row in data.rows do
			if i > RC.MAX_RACERS then
				break
			end
			local me = row.userId == player.UserId
			local right = if row.status == "fin" then RC.formatTime(row.time) else "DNF"
			UI.label({
				Text = string.format("%s  %s  ·  %s  (%s)", if row.status == "fin" then RC.ordinal(row.place) else "—", tostring(row.name), right, tostring(row.vehicle or "")),
				Font = if me then UI.FONT_BLACK else UI.FONT,
				TextSize = 13,
				TextColor3 = if me then colors.stamina else colors.text,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = i,
				Parent = list,
			})
		end
	else
		local medalLine = {}
		for _, m in RC.MEDALS do
			table.insert(medalLine, m.icon .. " " .. m.name .. " " .. RC.formatTime(m.time))
		end
		UI.label({ Text = table.concat(medalLine, "\n"), TextSize = 13, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 176), Size = UDim2.new(1, 0, 0, 60), Parent = results })
		UI.label({ Text = "Personal best: " .. RC.formatTime(data.best), Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(0, 244), Size = UDim2.new(1, 0, 0, 18), Parent = results })
	end
	local ok = UI.button({ Text = "OK", TextSize = 16, Font = UI.FONT_BLACK, BackgroundColor3 = colors.accent, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 40), Parent = results })
	ok.Activated:Connect(closeResults)
	results.Visible = true
	selectForGamepad(ok)
	Phone.refresh(APP_ID)
end

---------------------------------------------------------------------------
-- Street race challenges
---------------------------------------------------------------------------
local picker: Frame
local incoming: Frame
local incomingId: string? = nil

local function closePicker()
	picker.Visible = false
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(picker) then
		GuiService.SelectedObject = nil
	end
end

local function openPicker(target: Player)
	clearChildren(picker)
	UI.label({ Text = "STREET RACE", Font = UI.FONT_BLACK, TextSize = 22, Size = UDim2.new(1, -44, 0, 26), Parent = picker })
	UI.label({ Text = "CHALLENGE " .. target.DisplayName:upper(), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = APP_COLOR, Position = UDim2.fromOffset(0, 27), Size = UDim2.new(1, -44, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = picker })
	closeButton(picker, closePicker)
	local status = UI.label({ Text = "Pick a route. You'll both be taken to the start.", TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 30), Parent = picker })
	local list = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 1, -84), Parent = picker }, {
		UI.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
	})
	local busy = false
	local first: TextButton? = nil
	for i, route in RC.ROUTES do
		local b = UI.button({ Text = "", BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, 0, 0, 56), LayoutOrder = i, Parent = list }, { UI.padding(8) })
		first = first or b
		UI.label({ Text = route.name, Font = UI.FONT_BLACK, TextSize = 14, Size = UDim2.new(1, -70, 0, 18), Parent = b })
		UI.label({ Text = distanceText(route.length), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(70, 18), Parent = b })
		UI.label({ Text = route.blurb, TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 22), Parent = b })
		b.Activated:Connect(function()
			if busy then
				return
			end
			busy = true
			status.Text = "Sending..."
			status.TextColor3 = colors.text
			local ok, message = invoke("challenge", target.UserId, route.id)
			busy = false
			if ok then
				closePicker()
				HUD.push("STREET RACE", message .. " They have " .. RC.CHALLENGE_SECONDS .. "s to accept.")
			else
				status.Text = message
				status.TextColor3 = colors.danger
			end
		end)
	end
	picker.Visible = true
	selectForGamepad(first)
end

local function closeIncoming()
	incoming.Visible = false
	incomingId = nil
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(incoming) then
		GuiService.SelectedObject = nil
	end
end

local function showChallenge(data: any)
	if type(data) ~= "table" or type(data.id) ~= "string" then
		return
	end
	clearChildren(incoming)
	incomingId = data.id
	local id = data.id
	UI.label({ Text = "🏁 STREET RACE CHALLENGE", Font = UI.FONT_BLACK, TextSize = 18, Size = UDim2.new(1, 0, 0, 24), Parent = incoming })
	UI.label({
		Text = string.format("%s wants to race you on %s (%s). You'll both be taken to the start line.", tostring(data.from), tostring(data.route), distanceText(tonumber(data.length) or 0)),
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 52),
		Parent = incoming,
	})
	local _, setFill = UI.bar({ Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 6), Parent = incoming }, colors.stamina)
	local status = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.danger, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 94), Size = UDim2.new(1, 0, 0, 16), Parent = incoming })
	local accept = UI.button({ Text = "ACCEPT", TextSize = 15, Font = UI.FONT_BLACK, BackgroundColor3 = colors.cash, TextColor3 = Color3.fromRGB(20, 30, 20), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(0.5, -4, 0, 40), Parent = incoming })
	local decline = UI.button({ Text = "DECLINE", TextSize = 15, Font = UI.FONT_BLACK, BackgroundColor3 = Color3.fromRGB(150, 60, 60), AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.new(0.5, -4, 0, 40), Parent = incoming })
	local busy = false
	local function answer(yes: boolean)
		if busy or incomingId ~= id then
			return
		end
		busy = true
		local ok, message = invoke("respond", id, yes)
		busy = false
		if ok or not yes then
			closeIncoming()
			if message ~= "" and yes then
				HUD.push("STREET RACE", message)
			end
		else
			status.Text = message
		end
	end
	accept.Activated:Connect(function()
		answer(true)
	end)
	decline.Activated:Connect(function()
		answer(false)
	end)
	incoming.Visible = true
	selectForGamepad(accept)
	local expires = tonumber(data.expires) or (now() + RC.CHALLENGE_SECONDS)
	task.spawn(function()
		while incomingId == id and incoming.Visible do
			local left = expires - now()
			setFill(left / RC.CHALLENGE_SECONDS)
			if left <= 0 then
				closeIncoming()
				break
			end
			task.wait(0.1)
		end
	end)
end

local function addMenuAction()
	local module = script.Parent:FindFirstChild("Social")
	if not module then
		return
	end
	local ok, Social = pcall(require, module)
	if not ok or type(Social) ~= "table" or type(Social.addMenuAction) ~= "function" then
		return
	end
	Social.addMenuAction({
		id = "race",
		label = "CHALLENGE TO RACE",
		order = 40,
		visible = function(target: Player)
			return isDriving(player) and isDriving(target) and (player:GetAttribute("Race") or "") == ""
		end,
		run = function(target: Player)
			openPicker(target)
		end,
	})
end

---------------------------------------------------------------------------
-- Phone app
---------------------------------------------------------------------------
local function buildApp(content: ScrollingFrame)
	local token = 0
	local function line(parent: Instance, text: string, y: number, props: { [string]: any }?): TextLabel
		local p: { [string]: any } = { Text = text, TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 16), Parent = parent }
		if props then
			for k, v in props do
				p[k] = v
			end
		end
		return UI.label(p)
	end

	local function draw(info: any, myToken: number)
		if myToken ~= token then
			return
		end
		Phone.clear(content)
		if type(info) ~= "table" then
			local c = Phone.card(content, 60, 1)
			line(c, "Couldn't reach Race Control. Try again in a moment.", 0, { TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 1, 0) })
			return
		end
		local stats = info.stats or {}
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end
		if isWet() then
			UI.label({ Text = "🌧 Wet roads right now: less grip in every corner.", TextSize = 12, TextColor3 = colors.xp, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 18), LayoutOrder = nextOrder(), Parent = content })
		end

		-- speedway
		local speedway = Phone.card(content, 196, nextOrder())
		line(speedway, RC.TRACK_NAME:upper(), 0, { Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 20) })
		local medal = RC.medalInfo(stats.medal or 0)
		line(speedway, string.format("Best %d-lap time: %s%s", RC.LAPS, RC.formatTime(stats.bestRace), if medal then "  " .. medal.icon else ""), 24, { Font = UI.FONT_BOLD })
		line(speedway, "Best lap: " .. RC.formatTime(stats.bestLap), 42, { TextColor3 = colors.subtext })
		local status = line(speedway, "", 60, { TextSize = 12, TextColor3 = colors.stamina, Size = UDim2.new(1, 0, 0, 30) })
		local trialButton = UI.button({ Text = "🏁 START TIME TRIAL", TextSize = 13, BackgroundColor3 = APP_COLOR, Position = UDim2.fromOffset(0, 94), Size = UDim2.new(1, 0, 0, 34), Parent = speedway })
		local gps = UI.button({ Text = "📍 GPS TO SPEEDWAY", TextSize = 13, BackgroundColor3 = colors.xp, Position = UDim2.fromOffset(0, 134), Size = UDim2.new(1, 0, 0, 34), Parent = speedway })
		local busy = false
		trialButton.Activated:Connect(function()
			if busy then
				return
			end
			busy = true
			local ok, message = invoke("trial")
			busy = false
			status.Text = message
			status.TextColor3 = if ok then colors.cash else colors.stamina
			if ok then
				Phone.setOpen(false)
			end
		end)
		gps.Activated:Connect(function()
			local t = info.track
			if type(t) == "table" and typeof(t.pos) == "Vector3" then
				Phone.setGPS(RC.TRACK_NAME, t.pos)
				status.Text = "GPS set. Drive up to RACE HQ by the start line."
				status.TextColor3 = colors.cash
			else
				status.Text = "The speedway is closed right now."
			end
		end)

		-- medals
		local medals = Phone.card(content, 100, nextOrder())
		line(medals, "TIME TRIAL MEDALS (" .. RC.LAPS .. " LAPS)", 0, { Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext })
		for i, m in RC.MEDALS do
			local have = (stats.medal or 0) >= m.id
			line(medals, string.format("%s %s under %s  ·  %s%s", m.icon, m.name, RC.formatTime(m.time), UI.formatCash(m.cash), if have then "  ✓" else ""), 4 + i * 18, { TextColor3 = if have then m.color else colors.text })
		end

		-- stats
		local statsCard = Phone.card(content, 76, nextOrder())
		line(statsCard, "YOUR RACING", 0, { Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext })
		line(statsCard, string.format("Races %d · Wins %d · Podiums %d · Trials %d\nStreet races %d · Street wins %d", stats.races or 0, stats.wins or 0, stats.podiums or 0, stats.trials or 0, stats.streetRaces or 0, stats.streetWins or 0), 18, { Size = UDim2.new(1, 0, 0, 34) })

		-- street routes
		UI.label({ Text = "STREET ROUTES", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = nextOrder(), Parent = content })
		local note = Phone.card(content, 58, nextOrder())
		line(note, "Pull up next to another driver, open the player menu on them and pick CHALLENGE TO RACE.", 0, { TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 1, 0) })
		local routeInfo: { [string]: any } = {}
		local routeList = if type(info.routes) == "table" then info.routes else {}
		for _, r in routeList do
			if type(r) == "table" and type(r.id) == "string" then
				routeInfo[r.id] = r
			end
		end
		for _, route in RC.ROUTES do
			local ri = routeInfo[route.id] or {}
			local c = Phone.card(content, 116, nextOrder())
			line(c, route.name, 0, { Font = UI.FONT_BOLD, TextSize = 14 })
			line(c, distanceText(route.length) .. "  ·  PB " .. RC.formatTime(ri.best) .. (if ri.ok == false then "  ·  CLOSED" else ""), 18, { TextSize = 12, TextColor3 = if ri.ok == false then colors.danger else colors.stamina })
			line(c, route.blurb, 34, { TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 28) })
			local routeGps = UI.button({ Text = "📍 GPS TO START", TextSize = 12, BackgroundColor3 = colors.panel, Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 0, 28), Parent = c })
			routeGps.Activated:Connect(function()
				local start = if typeof(ri.start) == "Vector3" then ri.start else route.points[1]
				Phone.setGPS(route.name, start)
			end)
		end

		-- recent results
		local recent = if type(info.recent) == "table" then info.recent else {}
		local rc = Phone.card(content, 42 + math.max(1, #recent) * 18, nextOrder())
		line(rc, "RECENT RESULTS", 0, { Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext })
		if #recent == 0 then
			line(rc, "No races yet.", 20, { TextColor3 = colors.subtext })
		end
		for i, e in recent do
			if type(e) ~= "table" then
				continue
			end
			local kind = if e.k == "trial" then "Trial" elseif e.k == "street" then "Street" else "Race"
			local result = if (e.p or 0) == 0 then "DNF" elseif e.k == "trial" then RC.formatTime(e.t) else string.format("%s of %d · %s", RC.ordinal(e.p), e.of or 1, RC.formatTime(e.t))
			line(rc, string.format("%s · %s · %s", kind, tostring(e.n or ""), result), 2 + i * 18, { TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextWrapped = false })
		end
	end

	local function render()
		token += 1
		local myToken = token
		Phone.clear(content)
		UI.label({ Text = "Loading...", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
		task.spawn(function()
			local ok, _, info = invoke("info")
			draw(if ok then info else nil, myToken)
		end)
	end
	return render
end

---------------------------------------------------------------------------
-- Events from the server
---------------------------------------------------------------------------
local function onEvent(kind: any, data: any)
	if kind == "Race" then
		onRace(data)
	elseif kind == "State" then
		onState(data)
	elseif kind == "Lap" and type(data) == "table" and current and data.id == (current :: Setup).id then
		local lastLap = data.lap == data.laps
		showBanner(string.format("%s  ·  %s", if lastLap then "FINAL LAP" else string.format("LAP %d/%d", data.lap, data.laps), RC.formatTime(data.lapTime)), if lastLap then Color3.fromRGB(255, 220, 60) else colors.text, 2.5)
	elseif kind == "Missed" and type(data) == "table" and current and data.id == (current :: Setup).id then
		showBanner("MISSED CHECKPOINT " .. tostring(data.next) .. "!\nTurn back and drive through it.", colors.danger, 2.5)
	elseif kind == "Finished" and type(data) == "table" and current and data.id == (current :: Setup).id then
		finishedTime = data.time
		local setup = current :: Setup
		local text = if setup.kind == "trial" then "FINISHED  ·  " .. RC.formatTime(data.time) else string.format("FINISHED %s  ·  %s", RC.ordinal(data.place), RC.formatTime(data.time))
		showBanner(text, Color3.fromRGB(255, 215, 60), 4)
		clearHighlight()
	elseif kind == "Out" and type(data) == "table" and current and data.id == (current :: Setup).id then
		outOfRace = true
		clearHighlight()
		refreshHud()
		showBanner("OUT OF THE RACE\n" .. tostring(data.reason or ""), colors.danger, 4)
	elseif kind == "Results" then
		showResults(data)
	elseif kind == "Lobby" and type(data) == "table" then
		lobbyState = data
		if panel.Visible then
			refreshPanelLobby()
		end
	elseif kind == "Panel" then
		openPanel(data)
	elseif kind == "Challenge" then
		showChallenge(data)
	elseif kind == "ChallengeClosed" and type(data) == "table" and data.id == incomingId then
		closeIncoming()
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Racing.start()
	Phone.addApp({ id = APP_ID, label = "Racing", icon = "🏁", color = APP_COLOR }, buildApp)

	gui = UI.new("ScreenGui", {
		Name = "CityGrindRacing",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 7,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildHud()
	panel = modal("RaceHQ", 360, 400, APP_COLOR)
	results = modal("RaceResults", 380, 420, Color3.fromRGB(255, 215, 60))
	picker = modal("RaceRoutes", 360, 380, APP_COLOR)
	incoming = modal("RaceChallenge", 340, 200, colors.stamina)

	task.spawn(addMenuAction)
	task.spawn(function()
		local folder = shared:WaitForChild("Remotes")
		local event = folder:WaitForChild("RacingEvent")
		remotes = folder
		event.OnClientEvent:Connect(onEvent)
	end)

	RunService.RenderStepped:Connect(updateFrame)

	-- close the HQ panel when you leave the start area; keep its countdown fresh
	task.spawn(function()
		while true do
			task.wait(0.5)
			if panel.Visible then
				local info = panelInfo
				local t = info and info.track
				local character = player.Character
				local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if t and typeof(t.pos) == "Vector3" and rootPart and (rootPart.Position - t.pos).Magnitude > RC.TRACK_RANGE then
					closePanel()
				else
					refreshPanelLobby()
				end
			end
		end
	end)

	-- a respawn ends any race HUD that is still around
	player.CharacterAdded:Connect(function()
		clearHighlight()
	end)
end

return Racing
