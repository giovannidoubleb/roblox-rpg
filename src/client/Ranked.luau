-- CITY GRIND: ranked basketball client (spec 54, 55).
-- The phone's Ranked app (queue buttons, tier + progress, placements, season
-- countdown, last 10 matches, season rewards, season badges), the on-screen
-- queue chip while searching, the "match found" banner and the post-match
-- rating card. The server decides everything; this only shows state and sends taps.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local RC = require(shared:WaitForChild("RankedConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Ranked = {}

local APP_ID = "Ranked"
local APP_COLOR = Color3.fromRGB(120, 180, 255)
local GOLD = Color3.fromRGB(255, 200, 60)
local WIN = Color3.fromRGB(110, 230, 120)
local LOSS = Color3.fromRGB(255, 95, 95)

local state: any = nil
local requestRemote: RemoteFunction? = nil
local appContent: ScrollingFrame? = nil
local busy = false
local gui: ScreenGui? = nil
local chip: Frame? = nil
local chipText: TextLabel? = nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d, h, m = seconds // 86400, (seconds % 86400) // 3600, (seconds % 3600) // 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", math.max(1, m))
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function commas(n: number): string
	return UI.formatCash(n):sub(2)
end

local function serverNow(): number
	if state and state.serverNow and state.receivedAt then
		return state.serverNow + (os.clock() - state.receivedAt)
	end
	return os.time()
end

local function signed(n: number): string
	return if n > 0 then "+" .. n elseif n < 0 then tostring(n) else "±0"
end

local render: () -> ()
local refreshChip: () -> ()

local function setState(newState: any)
	if type(newState) ~= "table" then
		return
	end
	newState.receivedAt = os.clock()
	state = newState
	refreshChip()
	if appContent and Phone.isOpen() and Phone.currentPage() == APP_ID then
		render()
	end
end

local function request(action: string, arg: any?): (boolean, string?)
	if not requestRemote or busy then
		return false, nil
	end
	busy = true
	local ok, success, msg, newState = pcall(function()
		return (requestRemote :: RemoteFunction):InvokeServer(action, arg)
	end)
	busy = false
	if not ok then
		return false, "Couldn't reach the server."
	end
	if newState then
		setState(newState)
	end
	return success == true, msg
end

local function card(height: number, order: number): Frame
	return Phone.card(appContent :: ScrollingFrame, height, order)
end

local function heading(parent: Instance, text: string, color: Color3?)
	UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = color or APP_COLOR, Size = UDim2.new(1, 0, 0, 16), Parent = parent })
end

---------------------------------------------------------------------------
-- App sections
---------------------------------------------------------------------------
local function renderSeason(order: number)
	local s = state.season
	local c = card(44, order)
	heading(c, string.upper(s.name) .. "  ·  " .. RC.SEASON_WEEKS .. " WEEKS", GOLD)
	UI.label({
		Text = "Ends in " .. duration(s.endsAt - serverNow()) .. "  ·  " .. os.date("!%b %d", s.endsAt) .. " UTC",
		TextSize = 12,
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = c,
	})
end

local function renderTier(order: number)
	local placing = state.placementsLeft > 0
	local tierColor = if placing then RC.UNRANKED_COLOR else RC.tierColor(state.tier)
	local c = card(128, order)
	UI.stroke(tierColor, 1.5, 0.2).Parent = c
	local info = RC.tierOf(state.rating)
	UI.label({ Text = if placing then "❔" else info.icon, TextSize = 34, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(44, 44), Parent = c })
	UI.label({ Text = if placing then "UNRANKED" else string.upper(state.label), Font = UI.FONT_BLACK, TextSize = 20, TextColor3 = tierColor, Position = UDim2.fromOffset(52, 0), Size = UDim2.new(1, -52, 0, 24), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
	local sub = if placing
		then string.format("Placement games: %d of %d left", state.placementsLeft, RC.PLACEMENTS)
		else string.format("%s rating  ·  peak %s", commas(state.rating), commas(state.peak))
	UI.label({ Text = sub, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(52, 24), Size = UDim2.new(1, -52, 0, 14), Parent = c })

	local _, setFill = UI.bar({ Position = UDim2.fromOffset(0, 52), Size = UDim2.new(1, 0, 0, 10), Parent = c }, tierColor)
	local barText
	if placing then
		setFill((RC.PLACEMENTS - state.placementsLeft) / RC.PLACEMENTS)
		barText = "Finish your placements to get a tier."
	elseif state.nextAt then
		setFill(state.progress)
		local nextInfo = RC.tierOf(state.nextAt)
		barText = string.format("%d to %s", math.max(0, state.nextAt - state.rating), nextInfo.label)
	else
		setFill(1)
		barText = "Top tier. Defend it."
	end
	UI.label({ Text = barText, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 0, 14), Parent = c })

	local streak = if state.streak >= 2 then "  ·  🔥 " .. state.streak .. " streak" else ""
	UI.label({
		Text = string.format("%dW - %dL this season%s", state.wins, state.losses, streak),
		Font = UI.FONT_BOLD,
		TextSize = 13,
		Position = UDim2.fromOffset(0, 82),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = c,
	})
	UI.label({
		Text = string.format("Best streak %d  ·  Career %dW - %dL", state.bestStreak, state.life.wins, state.life.losses),
		TextSize = 11,
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 100),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = c,
	})
end

local function renderQueue(order: number)
	local c = card(150, order)
	heading(c, "PLAY RANKED")
	if state.match then
		UI.label({ Text = "You're in a ranked " .. state.match.mode .. " at " .. state.match.court .. ". Good luck!", TextSize = 13, TextWrapped = true, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 40), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
		c.Size = UDim2.new(1, -20, 0, 76)
		return
	end
	if state.queue then
		local q = state.queue
		UI.label({
			Text = string.format("Searching for ranked %s%s...", q.mode, if q.group == 2 then " with your partner" else ""),
			Font = UI.FONT_BOLD,
			TextSize = 13,
			Position = UDim2.fromOffset(0, 22),
			Size = UDim2.new(1, 0, 0, 16),
			Parent = c,
		})
		UI.label({
			Text = string.format("%s  ·  rating range ±%d  ·  %d in queue", q.status, q.window, state.counts[q.mode] or 0),
			TextSize = 11,
			TextColor3 = colors.subtext,
			Position = UDim2.fromOffset(0, 40),
			Size = UDim2.new(1, 0, 0, 14),
			Parent = c,
		})
		local leave = UI.button({ Text = "LEAVE QUEUE", TextSize = 13, BackgroundColor3 = LOSS, Position = UDim2.fromOffset(0, 62), Size = UDim2.new(1, 0, 0, 34), Parent = c })
		leave.Activated:Connect(function()
			local _, msg = request("Leave")
			if msg then
				HUD.push("RANKED", msg)
			end
		end)
		c.Size = UDim2.new(1, -20, 0, 120)
		return
	end
	if not state.eligible then
		UI.label({ Text = "🔒 " .. (state.reason or "Not available yet."), TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 44), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
		UI.label({
			Text = string.format("Needs level %d+ (you: %d) and hooper rating %d+ (you: %.1f)", RC.MIN_LEVEL, state.level, RC.MIN_HOOPER_RATING, state.hooper),
			TextSize = 11,
			TextWrapped = true,
			TextColor3 = colors.subtext,
			Position = UDim2.fromOffset(0, 70),
			Size = UDim2.new(1, 0, 0, 30),
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = c,
		})
		c.Size = UDim2.new(1, -20, 0, 116)
		return
	end
	local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 40), Parent = c }, {
		UI.new("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 1, 0), CellPadding = UDim2.fromOffset(8, 0), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, mode in RC.MODES do
		local b = UI.button({ Text = "QUEUE " .. mode, TextSize = 15, Font = UI.FONT_BLACK, BackgroundColor3 = APP_COLOR, TextColor3 = Color3.fromRGB(10, 20, 40), LayoutOrder = i, Parent = row })
		b.Activated:Connect(function()
			local ok, msg = request("Queue", mode)
			HUD.push(if ok then "RANKED QUEUE" else "RANKED", msg or "Try again.")
		end)
	end
	local partyHint = if state.partySize == 2
		then "2v2: you and your party partner queue together."
		elseif state.partySize > 2 then "2v2 takes a party of exactly 2 (solo players are paired up)."
		else "2v2 solo: you'll be paired with a teammate. Party up with one friend to queue together."
	UI.label({
		Text = string.format("In queue: %d (1v1)  ·  %d (2v2)\n%s\nFirst to %d · %d placement games per season · leaving = loss", state.counts["1v1"] or 0, state.counts["2v2"] or 0, partyHint, 11, RC.PLACEMENTS),
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 56),
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = c,
	})
end

local RESULT_TEXT = { W = "WIN", L = "LOSS", NC = "NO CONTEST", UNRATED = "UNRATED", QUIT = "QUIT" }
local function resultColor(result: string): Color3
	return if result == "W" then WIN elseif result == "L" or result == "QUIT" then LOSS else colors.subtext
end

local function renderHistory(order: number)
	local list = state.history
	local c = card(26 + math.max(1, #list) * 34, order)
	heading(c, "LAST " .. RC.HISTORY_LIMIT .. " MATCHES")
	if #list == 0 then
		UI.label({ Text = "No ranked games yet.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 16), Parent = c })
		return
	end
	for i, h in list do
		local y = 22 + (i - 1) * 34
		local col = resultColor(h.result)
		UI.label({ Text = RESULT_TEXT[h.result] or h.result, Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = col, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(72, 14), Parent = c })
		UI.label({ Text = h.mode .. "  " .. h.score .. "  vs " .. h.opp, TextSize = 12, Position = UDim2.fromOffset(74, y), Size = UDim2.new(1, -140, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
		UI.label({ Text = signed(h.delta), Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = col, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(60, 14), Parent = c })
		UI.label({ Text = UI.timeAgo(h.t) .. "  ·  " .. commas(h.rating) .. " after", TextSize = 10, TextColor3 = colors.subtext, Position = UDim2.fromOffset(74, y + 15), Size = UDim2.new(1, -74, 0, 12), Parent = c })
	end
end

local function rewardLine(tier: string): string
	local r = RC.REWARDS[tier]
	local parts = { "$" .. commas(r.cash), commas(r.xp) .. " XP", "title" }
	if r.badge then
		table.insert(parts, "badge")
	end
	if r.item then
		table.insert(parts, "jacket")
	end
	return table.concat(parts, " · ")
end

local function renderRewards(order: number)
	local c = card(40 + #RC.TIERS * 22, order)
	heading(c, "SEASON REWARDS (FINAL TIER)", GOLD)
	UI.label({ Text = "Title \"" .. RC.seasonTitle(state.season.id, "Tier") .. "\" for every placed player. Platinum+ get an exclusive season badge.", TextSize = 10, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 22), Parent = c })
	for i = #RC.TIERS, 1, -1 do
		local t = RC.TIERS[i]
		local y = 40 + (#RC.TIERS - i) * 22
		local mine = state.placementsLeft == 0 and state.tier == t.name
		if mine then
			UI.new("Frame", { BackgroundColor3 = t.color, BackgroundTransparency = 0.8, Position = UDim2.fromOffset(-4, y - 2), Size = UDim2.new(1, 8, 0, 20), Parent = c }, { UI.corner(6) })
		end
		local floor = if t.floor == -math.huge then "" else " " .. t.floor .. "+"
		UI.label({ Text = t.icon .. " " .. t.name .. floor, Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = t.color, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(120, 16), Parent = c })
		UI.label({ Text = rewardLine(t.name), TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.new(1, -120, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
	end
end

local function renderBadges(order: number)
	local badges = state.badges
	local seasons = state.seasons
	if #badges == 0 and #seasons == 0 then
		return
	end
	local rows = #badges + math.min(#seasons, 5)
	local c = card(46 + rows * 26 + (if #badges > 0 then 32 else 0), order)
	heading(c, "SEASON BADGES & HISTORY", GOLD)
	local y = 22
	for _, b in badges do
		local col = RC.tierColor(b.tier)
		local showing = state.badge == b.id
		UI.label({ Text = "◆ " .. RC.seasonTitle(b.id, b.tier), Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = col, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -90, 0, 20), Parent = c })
		local btn = UI.button({ Text = if showing then "SHOWING ✓" else "SHOW", TextSize = 11, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(84, 22), Parent = c })
		btn.Activated:Connect(function()
			local _, msg = request("Badge", b.id)
			if msg then
				HUD.push("SEASON BADGE", msg)
			end
		end)
		y += 26
	end
	if #badges > 0 then
		local hide = UI.button({ Text = "HIDE BADGE", TextSize = 11, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(100, 24), Parent = c })
		hide.Activated:Connect(function()
			local _, msg = request("Badge", "")
			if msg then
				HUD.push("SEASON BADGE", msg)
			end
		end)
		y += 32
	end
	for i = 1, math.min(#seasons, 5) do
		local s = seasons[i]
		UI.label({
			Text = string.format("%s  ·  %s  ·  %s rating  ·  %dW-%dL", s.id, s.tier, commas(s.rating), s.wins, s.losses),
			TextSize = 11,
			TextColor3 = RC.tierColor(s.tier),
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 22),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = c,
		})
		y += 26
	end
end

render = function()
	local content = appContent
	if not content then
		return
	end
	Phone.clear(content)
	if not state then
		local c = Phone.card(content, 40, 1)
		UI.label({ Text = "Loading ranked...", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1), Parent = c })
		return
	end
	renderSeason(1)
	renderTier(2)
	renderQueue(3)
	renderHistory(4)
	renderRewards(5)
	renderBadges(6)
end

---------------------------------------------------------------------------
-- Queue chip, match found banner, result card
---------------------------------------------------------------------------
refreshChip = function()
	if not chip then
		return
	end
	local q = state and state.queue
	chip.Visible = q ~= nil and state.match == nil
end

local function buildOverlay()
	local g = UI.new("ScreenGui", { Name = "CityGrindRanked", ResetOnSpawn = false, IgnoreGuiInset = false, DisplayOrder = 4, Parent = player:WaitForChild("PlayerGui") })
	gui = g
	local c = UI.new("Frame", {
		Name = "QueueChip",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 52),
		Size = UDim2.fromOffset(280, 34),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = g,
	}, { UI.corner(17), UI.stroke(APP_COLOR, 1.5, 0.2) })
	chip = c
	chipText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -60, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
	local x = UI.button({ Text = "✕", TextSize = 14, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -5, 0.5, 0), Size = UDim2.fromOffset(40, 26), BackgroundColor3 = LOSS, Parent = c })
	x.Activated:Connect(function()
		local _, msg = request("Leave")
		if msg then
			HUD.push("RANKED", msg)
		end
	end)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.5 then
			return
		end
		accumulator = 0
		local q = state and state.queue
		if c.Visible and q and chipText then
			local waited = q.waited + (os.clock() - state.receivedAt)
			chipText.Text = string.format("🏆 RANKED %s  ·  %s  ·  %s", q.mode, clock(waited), q.status)
		end
	end)
end

local function popup(height: number, stroke: Color3): Frame
	local frame = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(330, height),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		Parent = gui,
	}, { UI.corner(16), UI.stroke(stroke, 2, 0.1), UI.padding(14) })
	local scale = UI.new("UIScale", { Scale = 0.6, Parent = frame })
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	return frame
end

local function dismissLater(frame: Frame, seconds: number)
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		local scale = frame:FindFirstChildOfClass("UIScale")
		if scale then
			local t = TweenService:Create(scale, TweenInfo.new(0.2), { Scale = 0 })
			t:Play()
			t.Completed:Wait()
		end
		frame:Destroy()
	end
	local tap = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = frame })
	tap.Activated:Connect(close)
	task.delay(seconds, close)
end

local function names(list: { any }): string
	local out = {}
	for _, o in list do
		table.insert(out, o.name .. (if o.label then " (" .. o.label .. ")" else ""))
	end
	return table.concat(out, " & ")
end

local function showFound(info: any)
	if not gui or type(info) ~= "table" then
		return
	end
	local frame = popup(132, GOLD)
	UI.label({ Text = "MATCH FOUND", Font = UI.FONT_BLACK, TextSize = 24, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 26), Parent = frame })
	UI.label({ Text = "RANKED " .. tostring(info.mode) .. "  ·  " .. tostring(info.court), Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 16), Parent = frame })
	local vs = "vs " .. names(info.opponents or {})
	if info.teammates and #info.teammates > 0 then
		vs = "with " .. names(info.teammates) .. "\n" .. vs
	end
	UI.label({ Text = vs, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 32), Parent = frame })
	local countdown = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = if info.unrated then colors.subtext else APP_COLOR, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, 0, 0, 18), Parent = frame })
	local ends = os.clock() + (tonumber(info.countdown) or 6)
	task.spawn(function()
		while frame.Parent and os.clock() < ends do
			countdown.Text = (if info.unrated then "UNRATED (same opponent, daily limit)  ·  " else "") .. "TIP-OFF IN " .. math.ceil(ends - os.clock())
			task.wait(0.2)
		end
	end)
	dismissLater(frame, (tonumber(info.countdown) or 6) + 1)
end

local function showResult(info: any)
	if not gui or type(info) ~= "table" then
		return
	end
	local col = resultColor(info.result)
	local frame = popup(170, col)
	local title = RESULT_TEXT[info.result] or tostring(info.result)
	UI.label({ Text = title .. "  " .. tostring(info.score or ""), Font = UI.FONT_BLACK, TextSize = 24, TextColor3 = col, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 26), Parent = frame })
	local deltaText = signed(tonumber(info.delta) or 0)
	if (tonumber(info.bonus) or 0) > 0 then
		deltaText ..= "  (🔥 +" .. info.bonus .. " streak)"
	end
	UI.label({ Text = deltaText, Font = UI.FONT_BLACK, TextSize = 30, TextColor3 = col, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 34), Parent = frame })
	local line = tostring(info.label) .. "  ·  " .. commas(tonumber(info.rating) or 0) .. " rating"
	if info.oldLabel and info.oldLabel ~= info.label and (info.placementsLeft or 0) == 0 then
		local old = RC.TIER_INDEX[tostring(info.oldLabel):match("^(%a+)") or ""] or 0
		local new = RC.TIER_INDEX[tostring(info.label):match("^(%a+)") or ""] or 0
		if tostring(info.oldLabel):find("^Placement") then
			line = "PLACED: " .. line
		elseif new > old or (new == old and (tonumber(info.delta) or 0) > 0) then
			line = "PROMOTED! " .. line
		else
			line = "Demoted. " .. line
		end
	end
	UI.label({ Text = line, Font = UI.FONT_BOLD, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 0, 18), Parent = frame })
	local extra = {}
	if info.cash then
		table.insert(extra, "+$" .. commas(info.cash) .. "  ·  +" .. commas(info.xp or 0) .. " XP")
	end
	if (info.streak or 0) >= 2 then
		table.insert(extra, "🔥 " .. info.streak .. " win streak")
	end
	if info.reason then
		table.insert(extra, info.reason)
	end
	UI.label({ Text = table.concat(extra, "\n"), TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 90), Size = UDim2.new(1, 0, 0, 52), Parent = frame })
	dismissLater(frame, 8)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Ranked.start()
	Phone.addApp({ id = APP_ID, label = "Ranked", icon = "🏆", color = APP_COLOR }, function(content)
		appContent = content
		render()
		return function()
			render()
			task.spawn(request, "Get")
		end
	end)

	task.spawn(function()
		buildOverlay()
		local remotes = shared:WaitForChild("Remotes")
		local event = remotes:WaitForChild("RankedEvent") :: RemoteEvent
		requestRemote = remotes:WaitForChild("RankedRequest") :: RemoteFunction
		event.OnClientEvent:Connect(function(kind: string, data: any)
			if kind == "State" then
				setState(data)
			elseif kind == "Found" then
				showFound(data)
			elseif kind == "Result" then
				showResult(data)
			elseif kind == "Open" then
				Phone.setOpen(true)
				Phone.showPage(APP_ID)
			end
		end)
		if not player:GetAttribute("DataLoaded") then
			player:GetAttributeChangedSignal("DataLoaded"):Wait()
		end
		request("Get")
		-- keep the season countdown and queue numbers fresh while the app is open
		while true do
			task.wait(10)
			if Phone.isOpen() and Phone.currentPage() == APP_ID and not busy then
				request("Get")
			end
		end
	end)
end

return Ranked
