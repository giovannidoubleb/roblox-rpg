-- CITY GRIND: city events client (spec sections 41, 57, 58, 63, 92, 114).
-- The Events phone app (Upcoming / Live / Results + the community goal), the
-- live event panel (timer, standings, your status), the 5K next-gate
-- highlight and the Car Meet vote panel. The server runs every event and
-- judges everything; this module only shows its data and sends taps.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local EC = require(shared:WaitForChild("EventsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Events = {}

local APP_ID = "Events"
local APP_COLOR = Color3.fromRGB(255, 120, 60)

local remotes: Instance? = nil
local requestRemote: RemoteFunction? = nil

local snapshot: any = nil
local tab = "Upcoming"
local pickerFor: string? = nil -- event id whose invite picker is open
local ticking: { { label: TextLabel, fn: () -> string } } = {}
local appContent: ScrollingFrame? = nil
local busy = false

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function request(action: string, ...): any
	if not requestRemote then
		return nil
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return (requestRemote :: RemoteFunction):InvokeServer(action, table.unpack(args, 1, args.n))
	end)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

local function kindColor(kind: string): Color3
	local k = EC.KINDS[kind]
	return if k then k.color else APP_COLOR
end

---------------------------------------------------------------------------
-- Live panel (HUD)
---------------------------------------------------------------------------
local gui: ScreenGui
local panel: Frame
local titleLabel: TextLabel
local phaseLabel: TextLabel
local timerLabel: TextLabel
local statusLabel: TextLabel
local linesLabel: TextLabel
local leaveButton: TextButton
local voteButton: TextButton
local highlight: Highlight

local liveById: { [string]: { data: any, at: number } } = {}
local shown: any = nil

local votePanel: Frame
local voteData: any = nil
local openVote: (any) -> ()

local function pickShown(): any
	local best, bestAt = nil, -math.huge
	for _, entry in liveById do
		local score = entry.at + (if entry.data.role == "player" then 1000 else 0)
		if os.clock() - entry.at < 3 and score > bestAt then
			best, bestAt = entry.data, score
		end
	end
	return best
end

local function gateModel(index: number): Instance?
	local city = Workspace:FindFirstChild("City")
	local events = city and city:FindFirstChild("Events")
	local run = events and events:FindFirstChild("City5K")
	return run and run:FindFirstChild("Gate" .. index)
end

local function renderPanel()
	shown = pickShown()
	if not shown then
		panel.Visible = false
		highlight.Adornee = nil
		return
	end
	panel.Visible = true
	local color = kindColor(shown.kind)
	titleLabel.Text = string.format("%s %s", shown.icon or "", (shown.name or ""):upper())
	titleLabel.TextColor3 = color
	phaseLabel.Text = (shown.phase or "") .. (if shown.role == "watcher" then "  ·  watching" else "")
	statusLabel.Text = shown.status or ""
	statusLabel.TextColor3 = if shown.highlight then colors.stamina else colors.text
	linesLabel.Text = table.concat(shown.lines or {}, "\n")
	leaveButton.Text = if shown.role == "watcher" then "STOP WATCHING" else "LEAVE"
	voteButton.Visible = shown.canVote == true
	local gps = shown.gps
	if type(gps) == "table" and type(gps.index) == "number" then
		highlight.Adornee = gateModel(gps.index)
	else
		highlight.Adornee = nil
	end
end

local function buildPanel()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindEvents",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 3,
		Parent = player:WaitForChild("PlayerGui"),
	})
	-- under the stats card, top-right
	panel = UI.new("Frame", {
		Name = "EventPanel",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.12,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 112),
		Size = UDim2.fromOffset(230, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.padding(10), UI.stroke(APP_COLOR, 1.5, 0.4) })
	UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = panel })
	titleLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, Size = UDim2.new(1, 0, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 1, Parent = panel })
	local row = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 2, Parent = panel })
	phaseLabel = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -70, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
	timerLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(70, 16), Parent = row })
	statusLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = panel })
	linesLabel = UI.label({
		Text = "",
		TextSize = 12,
		TextColor3 = colors.subtext,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 4,
		Parent = panel,
	})
	local buttons = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 5, Parent = panel })
	UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Right, Parent = buttons })
	voteButton = UI.button({ Text = "🗳️ VOTE", TextSize = 12, BackgroundColor3 = kindColor("CarMeet"), Size = UDim2.fromOffset(80, 28), Visible = false, Parent = buttons })
	leaveButton = UI.button({ Text = "LEAVE", TextSize = 12, BackgroundColor3 = colors.danger, Size = UDim2.fromOffset(110, 28), Parent = buttons })

	leaveButton.Activated:Connect(function()
		local data = shown
		if not data then
			return
		end
		local result = request(if data.role == "watcher" then "Unwatch" else "Leave", data.id)
		liveById[data.id] = nil
		renderPanel()
		if result and result.msg then
			HUD.push("EVENTS", result.msg)
		end
		Phone.refresh(APP_ID)
	end)
	voteButton.Activated:Connect(function()
		if voteData then
			openVote(voteData)
		end
	end)

	highlight = Instance.new("Highlight")
	highlight.Name = "NextGate"
	highlight.FillColor = Color3.fromRGB(255, 80, 200)
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.35
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = gui

	RunService.RenderStepped:Connect(function()
		if not panel.Visible or not shown then
			return
		end
		local t = now()
		if (shown.timerFrom or 0) > 0 and t >= shown.timerFrom then
			timerLabel.Text = "⏱ " .. EC.formatTime(t - shown.timerFrom)
		elseif (shown.endsAt or 0) > t then
			timerLabel.Text = "⏳ " .. EC.formatIn(shown.endsAt - t)
		else
			timerLabel.Text = ""
		end
	end)
	-- drop stale data (event ended while a push was lost)
	task.spawn(function()
		while true do
			task.wait(1)
			if shown and not pickShown() then
				renderPanel()
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Car Meet vote panel
---------------------------------------------------------------------------
local voteTimer: TextLabel
local voteList: ScrollingFrame

local function closeVote()
	votePanel.Visible = false
end

local function renderVote()
	local data = voteData
	if not data then
		closeVote()
		return
	end
	for _, child in voteList:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local order = 0
	for catIndex, cat in data.categories do
		order += 1
		UI.label({ Text = cat:upper(), Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = kindColor("CarMeet"), Size = UDim2.new(1, 0, 0, 18), LayoutOrder = order, Parent = voteList })
		for _, c in data.candidates do
			order += 1
			local isMe = c.userId == data.you
			local picked = data.mine and data.mine[cat] == c.userId
			local detail = if catIndex == 1
				then c.vehicle
				elseif catIndex == 2 then c.paint .. " paint"
				else string.format("%s rims · %s glow", c.rim, c.glow)
			local b = UI.button({
				Text = "",
				BackgroundColor3 = if picked then Color3.fromRGB(110, 70, 200) else colors.panelLight,
				AutoButtonColor = not isMe,
				Size = UDim2.new(1, 0, 0, 40),
				LayoutOrder = order,
				Parent = voteList,
			})
			UI.label({ Text = string.format("Bay %d · %s%s", c.bay, c.name, if isMe then " (you)" else ""), Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(10, 3), Size = UDim2.new(1, -40, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = b })
			UI.label({ Text = detail, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(10, 20), Size = UDim2.new(1, -40, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = b })
			UI.label({ Text = if picked then "✓" else "", Font = UI.FONT_BLACK, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.new(0, 24, 1, 0), Parent = b })
			if not isMe then
				b.Activated:Connect(function()
					local result = request("Vote", data.id, catIndex, c.userId)
					if result and result.ok and type(result.mine) == "table" then
						data.mine = result.mine
						renderVote()
					elseif result and result.msg then
						HUD.push("CAR MEET", result.msg)
					end
				end)
			end
		end
	end
	order += 1
	UI.label({ Text = "You can't vote for your own car. Change a vote any time before the timer ends.", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order, Parent = voteList })
end

function openVote(data: any)
	voteData = data
	renderVote()
	votePanel.Visible = true
end

local function buildVotePanel()
	votePanel = UI.new("Frame", {
		Name = "CarMeetVote",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 340, 0.7, 0),
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	}, { UI.corner(16), UI.padding(14), UI.stroke(kindColor("CarMeet"), 2, 0.2) })
	UI.new("UISizeConstraint", { MaxSize = Vector2.new(340, 520), MinSize = Vector2.new(260, 240), Parent = votePanel })
	UI.label({ Text = "🚗 CAR MEET VOTE", Font = UI.FONT_BLACK, TextSize = 18, Size = UDim2.new(1, -40, 0, 22), Parent = votePanel })
	voteTimer = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, -40, 0, 14), Parent = votePanel })
	local close = UI.button({ Text = "✕", TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(32, 32), Parent = votePanel })
	close.Activated:Connect(closeVote)
	voteList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 1, -46),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = votePanel,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	RunService.Heartbeat:Connect(function()
		if votePanel.Visible and voteData then
			local left = voteData.endsAt - now()
			voteTimer.Text = if left > 0 then "Voting closes in " .. EC.formatIn(left) else "Counting votes…"
		end
	end)
end

---------------------------------------------------------------------------
-- Events phone app
---------------------------------------------------------------------------
local render: () -> ()

local function refetch()
	if busy then
		return
	end
	busy = true
	local result = request("List")
	busy = false
	if result and result.ok and type(result.data) == "table" then
		snapshot = result.data
		if appContent then
			render()
		end
	end
end

local function act(action: string, id: string, ...)
	local result = request(action, id, ...)
	if not result then
		HUD.push("EVENTS", "Couldn't reach the server. Try again.")
		return nil
	end
	if result.msg then
		HUD.push(if result.ok then "EVENTS" else "CAN'T DO THAT", result.msg)
	end
	refetch()
	return result
end

local function smallButton(parent: Instance, text: string, color: Color3, order: number, onTap: () -> ()): TextButton
	local b = UI.button({ Text = text, TextSize = 11, BackgroundColor3 = color, Size = UDim2.new(0.25, -5, 1, 0), LayoutOrder = order, Parent = parent })
	b.Activated:Connect(onTap)
	return b
end

local function buttonRow(parent: Instance, y: number): Frame
	local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 30), Parent = parent })
	UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = row })
	return row
end

local function tick(label: TextLabel, fn: () -> string)
	label.Text = fn()
	table.insert(ticking, { label = label, fn = fn })
end

local function invitePicker(content: ScrollingFrame, ev: any, order: number)
	local others = {}
	for _, p in Players:GetPlayers() do
		if p ~= player then
			table.insert(others, p)
		end
	end
	local height = 30 + math.max(1, #others) * 36
	local box = Phone.card(content, height, order)
	box.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
	UI.label({ Text = "INVITE TO " .. ev.name:upper(), Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = box })
	if #others == 0 then
		UI.label({ Text = "Nobody else is in this server right now.", TextSize = 12, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 30), Parent = box })
		return
	end
	for i, p in others do
		local b = UI.button({ Text = "📨  " .. p.DisplayName, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(0, 22 + (i - 1) * 36), Size = UDim2.new(1, 0, 0, 32), Parent = box }, { UI.padding(8) })
		b.Activated:Connect(function()
			act("Invite", ev.id, p.UserId)
		end)
	end
end

local function eventCard(content: ScrollingFrame, ev: any, order: number)
	local color = kindColor(ev.kind)
	local c = Phone.card(content, 216, order)
	UI.stroke(color, 1.5, if ev.joined then 0 else 0.7).Parent = c
	UI.label({ Text = ev.icon .. "  " .. ev.name, Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = color, Size = UDim2.new(1, -70, 0, 18), Parent = c })
	if ev.joined then
		UI.new("TextLabel", {
			Text = "JOINED",
			Font = UI.FONT_BLACK,
			TextSize = 11,
			TextColor3 = Color3.new(1, 1, 1),
			BackgroundColor3 = colors.cash,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(60, 18),
			Parent = c,
		}, { UI.corner(9) })
	end
	local whenLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 16), Parent = c })
	tick(whenLabel, function()
		local t = now()
		if ev.live then
			local left = ev.phaseEndsAt - t
			return "🔴 LIVE · " .. ev.phase .. (if left > 0 then " · " .. EC.formatIn(left) else "")
		end
		local left = ev.startsAt - t
		return string.format("📍 %s · %s", ev.location, if left > 0 then "in " .. EC.formatIn(left) else "starting…")
	end)
	UI.label({
		Text = string.format("%d / %d players · about %d min%s", ev.count, ev.maxPlayers, ev.duration, if ev.postponed then " · postponed" else ""),
		TextSize = 12,
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = c,
	})
	UI.label({ Text = ev.blurb, TextSize = 12, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 44), Parent = c })
	UI.label({ Text = (if ev.kind == "CarMeet" then "Each award: " else "1st: ") .. ev.firstPrize, Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 0, 14), Parent = c })
	UI.label({ Text = "Taking part: " .. ev.entryPrize, TextSize = 12, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 120), Size = UDim2.new(1, 0, 0, 14), Parent = c })
	UI.label({
		Text = if #ev.participants > 0 then "👥 " .. table.concat(ev.participants, ", ") else "👥 Nobody yet. Be the first!",
		TextSize = 12,
		TextColor3 = colors.subtext,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(0, 138),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = c,
	})

	local row = buttonRow(c, 160)
	if ev.joined then
		smallButton(row, "LEAVE", colors.danger, 1, function()
			act("Leave", ev.id)
		end)
	elseif ev.joinable then
		smallButton(row, "JOIN", Color3.fromRGB(40, 170, 90), 1, function()
			local result = act("Join", ev.id)
			if result and result.ok and typeof(result.position) == "Vector3" then
				Phone.setGPS(ev.name, result.position)
			end
		end)
	else
		smallButton(row, if ev.live then "CLOSED" else "FULL", Color3.fromRGB(70, 70, 80), 1, function()
			HUD.push("EVENTS", if ev.live then "Sign-ups are closed. Tap WATCH to follow it live." else "This event is full.")
		end)
	end
	if ev.live then
		smallButton(row, if ev.watching then "UNWATCH" else "WATCH", Color3.fromRGB(60, 120, 220), 2, function()
			local result = act(if ev.watching then "Unwatch" else "Watch", ev.id)
			if result and result.ok and typeof(result.position) == "Vector3" then
				Phone.setGPS(ev.name, result.position)
			end
		end)
	else
		smallButton(row, if ev.reminder then "🔔 ON" else "REMIND", if ev.reminder then Color3.fromRGB(200, 150, 30) else Color3.fromRGB(70, 70, 90), 2, function()
			act("Remind", ev.id, not ev.reminder)
		end)
	end
	smallButton(row, "📍 GPS", Color3.fromRGB(60, 160, 230), 3, function()
		Phone.setGPS(ev.name, ev.position)
		HUD.push("WAYPOINT SET", ev.name .. " at " .. ev.location .. ".")
	end)
	smallButton(row, if pickerFor == ev.id then "CLOSE" else "INVITE", Color3.fromRGB(150, 90, 255), 4, function()
		pickerFor = if pickerFor == ev.id then nil else ev.id
		render()
	end)
	UI.label({ Text = "Rewards are cash, XP and reputation only.", TextSize = 10, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 194), Size = UDim2.new(1, 0, 0, 12), Parent = c })
	if pickerFor == ev.id then
		invitePicker(content, ev, order + 1)
	end
end

local function goalCard(content: ScrollingFrame, order: number)
	local g = snapshot.goal
	local c = Phone.card(content, 104, order)
	c.BackgroundColor3 = Color3.fromRGB(30, 40, 70)
	UI.label({ Text = "🏙️ COMMUNITY GOAL", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = Color3.fromRGB(150, 190, 255), Size = UDim2.new(1, 0, 0, 14), Parent = c })
	UI.label({ Text = g.text, Font = UI.FONT_BOLD, TextSize = 13, TextWrapped = true, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 32), Parent = c })
	local _, set = UI.bar({ Position = UDim2.fromOffset(0, 52), Size = UDim2.new(1, 0, 0, 8), Parent = c }, if g.done then colors.cash else colors.xp)
	set(g.progress / math.max(1, g.target))
	local status = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 0, 14), Parent = c })
	tick(status, function()
		return string.format("%d / %d%s · %s", g.progress, g.target, if g.done then " · DONE ✓" else "", "resets in " .. EC.formatIn(g.endsAt - now()))
	end)
	UI.label({ Text = g.reward, TextSize = 11, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 78), Size = UDim2.new(1, 0, 0, 14), Parent = c })
end

local function tabBar(content: ScrollingFrame)
	local bar = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = 0, Parent = content })
	UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = bar })
	local liveCount = 0
	for _, ev in snapshot.events do
		if ev.live then
			liveCount += 1
		end
	end
	for i, name in { "Upcoming", "Live", "Results" } do
		local label = if name == "Live" and liveCount > 0 then "Live (" .. liveCount .. ")" else name
		local b = UI.button({
			Text = label,
			TextSize = 12,
			BackgroundColor3 = if tab == name then APP_COLOR else colors.panelLight,
			Size = UDim2.new(1 / 3, -4, 1, 0),
			LayoutOrder = i,
			Parent = bar,
		})
		b.Activated:Connect(function()
			tab = name
			pickerFor = nil
			render()
		end)
	end
end

local function meCard(content: ScrollingFrame, order: number)
	local me = snapshot.me
	local c = Phone.card(content, 62, order)
	UI.label({ Text = "YOUR EVENT RECORD", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = c })
	UI.label({
		Text = string.format(
			"5K best %s · 3PT best %s\nWins %d · Podiums %d · Car awards %d",
			if me.best5k > 0 then EC.formatTime(me.best5k) else "—",
			if me.best3pt > 0 then tostring(me.best3pt) else "—",
			me.wins,
			me.podiums,
			me.carAwards
		),
		TextSize = 12,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = c,
	})
end

function render()
	local content = appContent
	if not content then
		return
	end
	Phone.clear(content)
	table.clear(ticking)
	if not snapshot then
		UI.label({ Text = "Loading city events…", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
		return
	end
	tabBar(content)
	local order = 1
	if tab == "Upcoming" then
		goalCard(content, order)
		order += 1
		local any = false
		for _, ev in snapshot.events do
			if not ev.live then
				any = true
				order += 2
				eventCard(content, ev, order)
			end
		end
		if not any then
			UI.label({ Text = "Nothing scheduled right now.", TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = order + 2, Parent = content })
		end
	elseif tab == "Live" then
		local any = false
		for _, ev in snapshot.events do
			if ev.live then
				any = true
				order += 2
				eventCard(content, ev, order)
			end
		end
		if not any then
			local nextEv = nil
			for _, ev in snapshot.events do
				if not ev.live and (not nextEv or ev.startsAt < nextEv.startsAt) then
					nextEv = ev
				end
			end
			local c = Phone.card(content, 60, order + 1)
			local label = UI.label({ Text = "", TextSize = 13, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = c })
			tick(label, function()
				if nextEv then
					return string.format("Nothing live right now.\nNext: %s %s in %s", nextEv.icon, nextEv.name, EC.formatIn(nextEv.startsAt - now()))
				end
				return "Nothing live right now."
			end)
		end
	else
		meCard(content, order)
		if #snapshot.results == 0 then
			UI.label({ Text = "No events have finished yet this server.", TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = 2, Parent = content })
		end
		for i, r in snapshot.results do
			local lines = r.lines or {}
			local c = Phone.card(content, 46 + #lines * 16, 2 + i)
			UI.label({ Text = r.icon .. "  " .. r.name, Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = kindColor(r.kind), Size = UDim2.new(1, -60, 0, 16), Parent = c })
			local ago = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(60, 16), Parent = c })
			tick(ago, function()
				local m = math.floor((now() - r.at) / 60)
				return if m < 1 then "just now" else m .. "m ago"
			end)
			UI.label({
				Text = table.concat(lines, "\n"),
				TextSize = 12,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(0, 20),
				Size = UDim2.new(1, 0, 0, #lines * 16),
				Parent = c,
			})
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function onUpdate(kind: string, a: any, b: any)
	if kind == "Changed" then
		if Phone.isOpen() and Phone.currentPage() == APP_ID then
			task.spawn(refetch)
		end
	elseif kind == "Live" and type(a) == "table" and type(a.id) == "string" then
		liveById[a.id] = { data = a, at = os.clock() }
		if voteData and voteData.id == a.id then
			voteData.endsAt = a.endsAt or voteData.endsAt
		end
		renderPanel()
	elseif kind == "Closed" and type(a) == "string" then
		liveById[a] = nil
		if voteData and voteData.id == a then
			voteData = nil
			closeVote()
		end
		renderPanel()
	elseif kind == "Vote" and type(a) == "table" then
		openVote(a)
	elseif kind == "VoteClosed" and type(a) == "string" then
		if voteData and voteData.id == a then
			voteData = nil
			closeVote()
		end
	elseif kind == "Gps" and type(a) == "string" and typeof(b) == "Vector3" then
		Phone.setGPS(a, b)
	end
end

local function setup()
	remotes = shared:WaitForChild("Remotes")
	requestRemote = (remotes :: Instance):WaitForChild("EventsRequest") :: RemoteFunction
	local update = (remotes :: Instance):WaitForChild("EventsUpdate") :: RemoteEvent
	buildPanel()
	buildVotePanel()
	update.OnClientEvent:Connect(onUpdate)

	-- tick countdowns in the open app
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		if not (Phone.isOpen() and Phone.currentPage() == APP_ID) then
			return
		end
		for _, entry in ticking do
			if entry.label.Parent then
				entry.label.Text = entry.fn()
			end
		end
	end)
end

function Events.start()
	Phone.addApp({ id = APP_ID, label = "Events", icon = "🎟️", color = APP_COLOR }, function(content: ScrollingFrame)
		appContent = content
		render()
		return function()
			if snapshot then
				render()
			end
			refetch()
		end
	end)
	task.spawn(setup)
end

return Events
