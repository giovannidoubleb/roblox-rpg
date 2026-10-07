-- CITY GRIND: crew battles (section 62). Client side.
-- * "Battles" phone app: crew rating card, current challenge / live scoreboard,
--   challenge builder (leaders & officers), weekly City Crew Cup, recent results.
-- * Live chip on screen while your crew is in a countdown / live battle (tap: open the app).
-- * Results card when a battle ends.
-- All actions go to the server (CrewBattleRequest), which validates everything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local CB = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("CrewBattlesConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local CrewBattles = {}

local APP_ID = "CrewBattles"
local APP_COLOR = Color3.fromRGB(230, 70, 110)
local GOOD = Color3.fromRGB(60, 170, 90)

local requestRemote: RemoteFunction? = nil
local getRemote: RemoteFunction? = nil
local content: ScrollingFrame? = nil
local snapshot: any = nil
local receivedAt = os.clock()
local busy = false
local tickers: { () -> () } = {} -- refresh countdown labels without rebuilding the page

-- challenge builder state
local form = { format = "Basketball", metric = "jobs", target = nil :: string? }

-- live chip
local chipGui: ScreenGui? = nil
local chip: TextButton? = nil
local chipData: any = nil
local chipReceivedAt = os.clock()
local chipTop: TextLabel
local chipBottom: TextLabel

local function serverNow(): number
	if snapshot and snapshot.serverNow then
		return snapshot.serverNow + (os.clock() - receivedAt)
	end
	return os.time()
end

local function duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d, h, m = seconds // 86400, (seconds % 86400) // 3600, (seconds % 3600) // 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return CB.clock(seconds)
end

local function onPage(): boolean
	return content ~= nil and Phone.isOpen() and Phone.currentPage() == APP_ID
end

---------------------------------------------------------------------------
-- Server calls
---------------------------------------------------------------------------
local render: () -> ()

local function fetch()
	if not getRemote then
		return
	end
	task.spawn(function()
		local ok, result = pcall(function()
			return (getRemote :: RemoteFunction):InvokeServer()
		end)
		if ok and type(result) == "table" then
			snapshot = result
			receivedAt = os.clock()
			if onPage() then
				render()
			end
		end
	end)
end

local function request(action: string, args: any)
	if not requestRemote or busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = pcall(function()
			return (requestRemote :: RemoteFunction):InvokeServer(action, args)
		end)
		busy = false
		if ok and type(result) == "table" then
			if result.msg then
				HUD.push(if result.ok then "CREW BATTLES" else "CAN'T DO THAT", tostring(result.msg))
			end
		else
			HUD.push("CREW BATTLES", "Couldn't reach the server.")
		end
		fetch()
	end)
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
local function text(parent: Instance, props: { [string]: any }): TextLabel
	local defaults = { TextSize = 13, TextWrapped = true, Size = UDim2.new(1, 0, 0, 18) }
	for k, v in props do
		defaults[k] = v
	end
	defaults.Parent = parent
	return UI.label(defaults)
end

local function button(parent: Instance, label: string, color: Color3, pos: UDim2, size: UDim2, onTap: () -> ()): TextButton
	local b = UI.button({ Text = label, TextSize = 13, BackgroundColor3 = color, Position = pos, Size = size, Parent = parent })
	b.Activated:Connect(onTap)
	return b
end

local function crewCard(c: ScrollingFrame, order: number)
	local crew = snapshot.crew
	local card = Phone.card(c, 84, order)
	text(card, { Text = string.format("🛡️  %s  [%s]", crew.name, crew.tag), Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 22) })
	text(card, { Text = string.format("Crew rating %d  ·  %dW %dL %dD", crew.rating, crew.wins, crew.losses, crew.draws), TextColor3 = Color3.fromRGB(255, 210, 90), Font = UI.FONT_BOLD, Position = UDim2.fromOffset(0, 24) })
	local me = snapshot.me
	text(card, {
		Text = if me then string.format("You: %d battles · %d wins · %d MVP", me.played, me.wins, me.mvps) else "",
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 42),
	})
end

local function battleCard(c: ScrollingFrame, order: number)
	local b = snapshot.battle
	local mine = if b.mineIsA then b.a else b.b
	local theirs = if b.mineIsA then b.b else b.a
	local isPending = b.state == "pending"
	local height = if isPending then 170 else 214 + 18 * #b.top
	local card = Phone.card(c, height, order)
	card.BackgroundColor3 = Color3.fromRGB(46, 30, 40)
	text(card, { Text = b.icon .. "  " .. string.upper(b.formatName), Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = APP_COLOR })
	if isPending then
		local who = if b.mineIsA then "Challenge sent to " .. theirs.name else theirs.name .. " challenges your crew!"
		text(card, { Text = who, Font = UI.FONT_BOLD, Position = UDim2.fromOffset(0, 22) })
		text(card, { Text = b.desc, TextColor3 = colors.subtext, TextSize = 12, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 44) })
		local timer = text(card, { Text = "", TextColor3 = colors.stamina, Font = UI.FONT_BOLD, Position = UDim2.fromOffset(0, 88) })
		table.insert(tickers, function()
			timer.Text = "Expires in " .. CB.clock(b.acceptBy - serverNow())
		end)
		if b.canAccept then
			button(card, "ACCEPT", GOOD, UDim2.fromOffset(0, 110), UDim2.new(0.5, -4, 0, 30), function()
				request("Accept", b.id)
			end)
			button(card, "Decline", colors.panelLight, UDim2.new(0.5, 4, 0, 110), UDim2.new(0.5, -4, 0, 30), function()
				request("Decline", b.id)
			end)
		elseif b.canCancel then
			button(card, "Cancel challenge", colors.panelLight, UDim2.fromOffset(0, 110), UDim2.new(1, 0, 0, 30), function()
				request("Cancel", b.id)
			end)
		else
			text(card, { Text = if b.mineIsA then "Waiting for their leader or officers…" else "Your leader or officers can accept.", TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 114) })
		end
		return
	end
	-- scoreboard
	local board = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 56), Parent = card })
	local function side(s: any, x: number, align: Enum.TextXAlignment)
		UI.label({ Text = "[" .. tostring(s.tag) .. "] " .. s.name, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = align, TextColor3 = s.color, Position = UDim2.new(x, 0, 0, 0), Size = UDim2.new(0.5, -4, 0, 16), Parent = board })
		UI.label({ Text = tostring(s.score), Font = UI.FONT_BLACK, TextSize = 30, TextXAlignment = align, Position = UDim2.new(x, 0, 0, 16), Size = UDim2.new(0.5, -4, 0, 38), Parent = board })
	end
	side(mine, 0, Enum.TextXAlignment.Left)
	side(theirs, 0.5, Enum.TextXAlignment.Right)
	local timer = text(card, { Text = "", Font = UI.FONT_BOLD, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 84) })
	table.insert(tickers, function()
		local t = serverNow()
		if b.state == "countdown" and b.startsAt then
			timer.Text = "Starts in " .. CB.clock(b.startsAt - t)
		elseif b.state == "live" and b.endsAt then
			timer.Text = "Time left " .. CB.clock(b.endsAt - t)
		else
			timer.Text = "Final scores coming in…"
		end
	end)
	text(card, { Text = b.desc, TextColor3 = colors.subtext, TextSize = 12, Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 0, 44) })
	text(card, { Text = string.format("Your contribution: %d %s", b.myScore, b.unit), Font = UI.FONT_BOLD, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 150) })
	text(card, { Text = if #b.top > 0 then "TOP SCORERS ON THIS SERVER" else "", TextSize = 11, Font = UI.FONT_BOLD, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 170) })
	for i, e in b.top do
		text(card, {
			Text = string.format("%d. %s — %d", i, e.name, e.score),
			TextColor3 = if e.mine then mine.color else theirs.color,
			Position = UDim2.fromOffset(0, 170 + 18 * i),
		})
	end
end

local function builderCard(c: ScrollingFrame, order: number)
	local targets = snapshot.targets or {}
	local isCity = form.format == "CityChallenge"
	local rows = math.min(#targets, 8)
	local height = 244 + (if isCity then 36 else 0) + math.max(rows, 1) * 34
	local card = Phone.card(c, height, order)
	text(card, { Text = "⚔️  CHALLENGE A CREW", Font = UI.FONT_BLACK, TextSize = 14 })
	-- formats (2 rows)
	local y = 24
	for i, f in CB.FORMATS do
		local col, rowN = (i - 1) % 3, (i - 1) // 3
		local selected = form.format == f.id
		button(card, f.icon .. " " .. f.label, if selected then f.color else colors.panel, UDim2.new(col / 3, 2, 0, y + rowN * 36), UDim2.new(1 / 3, -4, 0, 32), function()
			form.format = f.id
			render()
		end).TextSize = 11
	end
	y += 76
	if isCity then
		for i, m in CB.METRICS do
			local selected = form.metric == m.id
			button(card, m.icon .. " " .. m.label, if selected then CB.BY_ID.CityChallenge.color else colors.panel, UDim2.new((i - 1) / 3, 2, 0, y), UDim2.new(1 / 3, -4, 0, 30), function()
				form.metric = m.id
				render()
			end).TextSize = 11
		end
		y += 36
	end
	local f = CB.BY_ID[form.format]
	local desc = if isCity then (CB.METRIC_BY_ID[form.metric].desc .. " " .. f.minutes .. " minutes.") else (f.desc .. " " .. f.minutes .. " minutes.")
	text(card, { Text = desc, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 48) })
	y += 52
	text(card, { Text = "OPPONENT", TextSize = 11, Font = UI.FONT_BOLD, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y) })
	y += 24
	if #targets == 0 then
		text(card, { Text = "No other crews found yet. Crews online in this server and crews on the rating board show up here.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 30) })
		y += 34
	end
	for i, t in targets do
		if i > 8 then
			break
		end
		local selected = form.target == t.id
		local label = string.format("%s%s · %d%s", t.name, if t.tag ~= "" then " [" .. t.tag .. "]" else "", t.rating, if t.busy then " · busy" elseif t.here then " · here" else " · other server")
		local b = button(card, label, if selected then APP_COLOR else colors.panel, UDim2.fromOffset(0, y), UDim2.new(1, 0, 0, 30), function()
			if not t.busy then
				form.target = t.id
				render()
			end
		end)
		b.TextSize = 12
		b.TextTruncate = Enum.TextTruncate.AtEnd
		if t.busy then
			b.TextColor3 = colors.subtext
		end
		y += 34
	end
	local ready = form.target ~= nil
	button(card, "SEND CHALLENGE", if ready then APP_COLOR else colors.panel, UDim2.fromOffset(0, y + 6), UDim2.new(1, 0, 0, 34), function()
		if form.target then
			request("Challenge", { target = form.target, format = form.format, metric = if isCity then form.metric else nil })
		else
			HUD.push("CREW BATTLES", "Pick an opponent first.")
		end
	end)
end

local function cupCard(c: ScrollingFrame, order: number)
	local cup = snapshot.cup
	if not cup then
		return
	end
	local n = #cup.standings
	local last = cup.lastWeek or {}
	local height = 88 + math.max(n, 1) * 18 + (if #last > 0 then 26 + #last * 18 else 0)
	local card = Phone.card(c, height, order)
	text(card, { Text = "🏆  CITY CREW CUP", Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = Color3.fromRGB(255, 205, 70) })
	local timer = text(card, { Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 20) })
	table.insert(tickers, function()
		timer.Text = string.format("3 pts a win · 1 a draw · resets in %s", duration(cup.endsAt - serverNow()))
	end)
	text(card, { Text = if snapshot.crew then string.format("Your crew this week: %d pts", cup.myPoints) else "", TextSize = 12, Font = UI.FONT_BOLD, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 38) })
	local y = 60
	if n == 0 then
		text(card, { Text = "No battles won yet this week.", TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y) })
		y += 18
	end
	for i, e in cup.standings do
		text(card, { Text = string.format("%d. %s — %d pts", i, e.name, e.points), Font = if e.mine then UI.FONT_BOLD else UI.FONT, TextColor3 = if e.mine then Color3.fromRGB(255, 225, 140) else colors.text, Position = UDim2.fromOffset(0, y) })
		y += 18
	end
	if #last > 0 then
		y += 8
		text(card, { Text = "LAST WEEK'S PODIUM", TextSize = 11, Font = UI.FONT_BOLD, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y) })
		y += 18
		for i, e in last do
			text(card, { Text = string.format("%s %s — %d pts", if i == 1 then "🥇" elseif i == 2 then "🥈" else "🥉", e.name, e.points), Position = UDim2.fromOffset(0, y) })
			y += 18
		end
	end
end

local function historyCard(c: ScrollingFrame, order: number)
	local hist = snapshot.history or {}
	if #hist == 0 then
		return
	end
	local card = Phone.card(c, 48 + #hist * 34, order)
	text(card, { Text = "RECENT BATTLES", TextSize = 11, Font = UI.FONT_BOLD, TextColor3 = colors.subtext })
	for i, r in hist do
		local y = 22 + (i - 1) * 34
		text(card, { Text = string.format("%s %s %d – %d %s", r.icon, r.a.name, r.a.score, r.b.score, r.b.name), Font = UI.FONT_BOLD, TextTruncate = Enum.TextTruncate.AtEnd, TextWrapped = false, Position = UDim2.fromOffset(0, y) })
		local outcome = if r.noContest then "No contest" elseif r.winner then r.winner .. " won" else "Draw"
		text(card, { Text = string.format("%s · %s · %s", r.formatName, outcome, UI.timeAgo(r.at)), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, y + 16) })
	end
end

render = function()
	local c = content
	if not c then
		return
	end
	table.clear(tickers)
	Phone.clear(c)
	if not snapshot then
		local card = Phone.card(c, 40, 1)
		text(card, { Text = "Loading…", TextColor3 = colors.subtext })
		return
	end
	if not snapshot.crew then
		local card = Phone.card(c, 128, 1)
		text(card, { Text = "⚔️  CREW BATTLES", Font = UI.FONT_BLACK, TextSize = 15 })
		text(card, { Text = "Crews battle in basketball, racing, running, treasure hunts and city challenges. Join or start a crew to compete.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 44) })
		button(card, "Open the Crew app", APP_COLOR, UDim2.fromOffset(0, 70), UDim2.new(1, 0, 0, 30), function()
			Phone.showPage("Crew")
		end)
	else
		crewCard(c, 1)
		if snapshot.battle then
			battleCard(c, 2)
		elseif snapshot.crew.canChallenge then
			builderCard(c, 3)
		else
			local card = Phone.card(c, 60, 3)
			text(card, { Text = "No battle right now. Your crew's leader or officers can challenge another crew from here.", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1) })
		end
	end
	cupCard(c, 4)
	historyCard(c, 5)
	local lb = UI.button({ Text = "🏆 Crew rating leaderboard", TextSize = 13, BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, -20, 0, 34), LayoutOrder = 6, Parent = c })
	lb.Activated:Connect(function()
		Phone.showPage("Leaderboards")
	end)
	if not snapshot.global then
		local card = Phone.card(c, 48, 7)
		text(card, { Text = "Offline mode: ratings and the cup are kept for this server only.", TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1) })
	end
	for _, fn in tickers do
		fn()
	end
end

---------------------------------------------------------------------------
-- Live chip and results card
---------------------------------------------------------------------------
local function buildGui()
	chipGui = UI.new("ScreenGui", {
		Name = "CityGrindCrewBattles",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 4,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local b = UI.new("TextButton", {
		Name = "Chip",
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.4, 0),
		Size = UDim2.fromOffset(230, 54),
		Visible = false,
		Parent = chipGui,
	}, { UI.corner(12), UI.stroke(APP_COLOR, 2) })
	HUD.slot("left", b, 30)
	chipTop = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(6, 4), Size = UDim2.new(1, -12, 0, 24), Parent = b })
	chipBottom = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(6, 28), Size = UDim2.new(1, -12, 0, 20), Parent = b })
	b.Activated:Connect(function()
		Phone.setOpen(true)
		Phone.showPage(APP_ID)
	end)
	chip = b
end

local function updateChip()
	if not chip then
		return
	end
	local d = chipData
	if not d or os.clock() - chipReceivedAt > 8 then
		chip.Visible = false
		return
	end
	chip.Visible = true
	local t = d.serverNow + (os.clock() - chipReceivedAt)
	chipTop.Text = string.format("%s  %s %d – %d %s", d.icon, d.mine.tag, d.mine.score, d.theirs.score, d.theirs.tag)
	local lead = d.mine.score - d.theirs.score
	chipTop.TextColor3 = if lead > 0 then Color3.fromRGB(120, 230, 140) elseif lead < 0 then Color3.fromRGB(255, 120, 120) else colors.text
	if d.state == "countdown" and d.startsAt then
		chipBottom.Text = string.format("%s · starts in %s", d.formatName, CB.clock(d.startsAt - t))
	elseif d.state == "live" and d.endsAt then
		chipBottom.Text = string.format("%s · %s left · you %d", d.formatName, CB.clock(d.endsAt - t), d.myScore)
	else
		chipBottom.Text = "Final scores coming in…"
	end
end

local function showResult(r: any)
	if not chipGui then
		return
	end
	local old = (chipGui :: ScreenGui):FindFirstChild("Result")
	if old then
		old:Destroy()
	end
	local accent = if r.outcome == "win" then Color3.fromRGB(90, 220, 120) elseif r.outcome == "loss" then Color3.fromRGB(255, 100, 100) else Color3.fromRGB(255, 200, 60)
	local card = UI.new("Frame", {
		Name = "Result",
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(320, 270),
		Parent = chipGui,
	}, { UI.corner(18), UI.stroke(accent, 3), UI.padding(14) })
	local headline = if r.outcome == "win" then "VICTORY!" elseif r.outcome == "loss" then "DEFEAT" elseif r.outcome == "draw" then "DRAW" else "NO CONTEST"
	UI.label({ Text = headline, Font = UI.FONT_BLACK, TextSize = 28, TextColor3 = accent, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 34), Parent = card })
	UI.label({ Text = tostring(r.icon) .. "  " .. tostring(r.formatName), TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 18), Parent = card })
	UI.label({
		Text = string.format("%s  %d – %d  %s", r.mine.name, r.mine.score, r.theirs.score, r.theirs.name),
		Font = UI.FONT_BLACK,
		TextSize = 17,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 0, 44),
		Parent = card,
	})
	local lines = {}
	if r.outcome ~= "none" then
		table.insert(lines, string.format("Crew rating %d (%s%d)", r.mine.rating, if r.mine.delta >= 0 then "+" else "", r.mine.delta))
	end
	table.insert(lines, string.format("Your contribution: %d %s", r.myScore or 0, tostring(r.unit)))
	if r.mvp then
		table.insert(lines, string.format("MVP: %s (%d)", r.mvp.name, r.mvp.score))
	end
	if r.reward then
		table.insert(lines, "Reward: " .. r.reward)
	end
	if r.note then
		table.insert(lines, tostring(r.note))
	end
	UI.label({ Text = table.concat(lines, "\n"), TextSize = 14, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 0, 90), Parent = card })
	local close = UI.button({ Text = "NICE", BackgroundColor3 = accent, TextColor3 = Color3.fromRGB(20, 20, 24), Position = UDim2.new(0, 0, 1, -38), Size = UDim2.new(1, 0, 0, 38), Parent = card })
	close.Activated:Connect(function()
		card:Destroy()
	end)
	task.delay(25, function()
		if card.Parent then
			card:Destroy()
		end
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function CrewBattles.start()
	Phone.addApp({ id = APP_ID, label = "Battles", icon = "⚔️", color = APP_COLOR }, function(page: ScrollingFrame)
		content = page
		render()
		return function()
			render()
			fetch()
		end
	end)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Remotes")
		requestRemote = remotes:WaitForChild("CrewBattleRequest") :: RemoteFunction
		getRemote = remotes:WaitForChild("CrewBattleGet") :: RemoteFunction
		local event = remotes:WaitForChild("CrewBattleEvent") :: RemoteEvent
		buildGui()
		event.OnClientEvent:Connect(function(kind: any, data: any)
			if kind == "changed" then
				if onPage() then
					fetch()
				end
			elseif kind == "live" then
				chipData = if type(data) == "table" then data else nil
				chipReceivedAt = os.clock()
				updateChip()
			elseif kind == "result" and type(data) == "table" then
				chipData = nil
				updateChip()
				showResult(data)
				fetch()
			end
		end)
		-- countdown labels / chip, and a slow refresh while the page shows a live battle
		local acc, slow = 0, 0
		RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.5 then
				return
			end
			acc = 0
			updateChip()
			if onPage() then
				for _, fn in tickers do
					pcall(fn)
				end
				slow += 1
				if slow >= 10 and snapshot and snapshot.battle then
					slow = 0
					fetch()
				end
			end
		end)
	end)
end

return CrewBattles
