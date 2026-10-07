-- CITY GRIND: leaderboards (section 98). Client side: the "Leaderboards" phone app.
-- Category tabs (level, cash, rep, fame, rating, wins, points, 5K, race, crews),
-- scopes All time / This season / Friends, your own rank line, and archived
-- seasons. Everything is read from the server (LeaderboardsGet); tapping a
-- player opens their profile card.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(script.Parent:WaitForChild("UI"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local LC = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("LeaderboardsConfig"))

local colors = UI.colors

local Leaderboards = {}

local APP_ID = "Leaderboards"
local APP_COLOR = Color3.fromRGB(255, 190, 40)
local ME_COLOR = Color3.fromRGB(60, 50, 20)

local remote: RemoteFunction? = nil
local content: ScrollingFrame? = nil

local state = {
	stat = "level",
	scope = "all", -- "all" | "season" | "friends"
	meta = nil :: any,
	board = nil :: any, -- last board reply
	boardKey = "", -- stat .. "|" .. scope of `board`
	seq = 0,
	archiveId = nil :: string?, -- viewing an archived season
	archive = nil :: any,
	archiveStat = "rating",
}

local function invoke(action: string, a: any?, b: any?): any
	if not remote then
		return nil
	end
	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer(action, a, b)
	end)
	return if ok and type(result) == "table" then result else nil
end

local function ago(t: number?): string
	if not t then
		return "live"
	end
	return "updated " .. UI.timeAgo(t)
end

local function socialClient(): any
	local m = script.Parent:FindFirstChild("Social")
	if not m then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok then mod else nil
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local render: () -> ()

local function chip(parent: Instance, text: string, selected: boolean, color: Color3, width: number, order: number, onTap: () -> ()): TextButton
	local b = UI.button({
		Text = text,
		TextSize = 13,
		Size = UDim2.fromOffset(width, 30),
		LayoutOrder = order,
		BackgroundColor3 = if selected then color else colors.panelLight,
		TextColor3 = if selected then Color3.fromRGB(20, 20, 24) else colors.text,
		Parent = parent,
	})
	b.Activated:Connect(onTap)
	return b
end

local function row(parent: Instance, order: number, rank: number, name: string, value: string, me: boolean, userId: number?)
	local f = UI.new("TextButton", {
		Text = "",
		AutoButtonColor = userId ~= nil,
		BackgroundColor3 = if me then ME_COLOR else colors.panelLight,
		Size = UDim2.new(1, -20, 0, 34),
		LayoutOrder = order,
		Parent = parent,
	}, { UI.corner(10) })
	local rankColor = if rank == 1 then Color3.fromRGB(255, 210, 70) elseif rank == 2 then Color3.fromRGB(205, 210, 220) elseif rank == 3 then Color3.fromRGB(215, 140, 70) else colors.subtext
	UI.label({ Text = "#" .. rank, Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = rankColor, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0, 40, 1, 0), Parent = f })
	UI.label({ Text = name .. (if me then "  (you)" else ""), Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(50, 0), Size = UDim2.new(1, -150, 1, 0), Parent = f })
	UI.label({ Text = value, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.cash, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -100, 0, 0), Size = UDim2.new(0, 90, 1, 0), Parent = f })
	if userId and userId > 0 then
		f.Activated:Connect(function()
			local Social = socialClient()
			if Social and type(Social.openProfile) == "function" then
				Social.openProfile(userId)
			end
		end)
	end
end

local function note(parent: Instance, order: number, text: string, color: Color3?)
	local c = Phone.card(parent, 56, order)
	UI.label({ Text = text, TextSize = 13, TextWrapped = true, TextColor3 = color or colors.subtext, Size = UDim2.fromScale(1, 1), Parent = c })
end

local function fetchBoard()
	local key = state.stat .. "|" .. state.scope
	state.seq += 1
	local seq = state.seq
	task.spawn(function()
		local reply = invoke("Board", state.stat, state.scope)
		if seq == state.seq and state.stat .. "|" .. state.scope == key then
			state.board = reply or { ok = false, msg = "Couldn't reach the server." }
			state.boardKey = key
			render()
		end
	end)
end

local function fetchMeta()
	task.spawn(function()
		local reply = invoke("Meta")
		if reply and reply.ok then
			state.meta = reply
			render()
		end
	end)
end

local function selectStat(id: string)
	state.stat = id
	local s = LC.BY_ID[id]
	local seasonGone = state.scope == "season" and not (s.seasonal and state.meta and state.meta.season)
	if seasonGone or (state.scope == "friends" and s.crew) then
		state.scope = "all"
	end
	state.board = nil
	render()
	fetchBoard()
end

local function renderArchive(c: ScrollingFrame)
	local back = UI.button({ Text = "‹ Back to live boards", TextSize = 14, TextColor3 = colors.xp, BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, -20, 0, 32), LayoutOrder = 1, Parent = c })
	back.Activated:Connect(function()
		state.archiveId = nil
		state.archive = nil
		render()
	end)
	local a = state.archive
	if not a then
		note(c, 2, "Loading the archive…")
		return
	end
	if not a.ok then
		note(c, 2, a.msg or "Archive unavailable.", colors.danger)
		return
	end
	local head = Phone.card(c, 68, 2)
	UI.label({ Text = "🏛️  " .. tostring(a.name), Font = UI.FONT_BLACK, TextSize = 17, Size = UDim2.new(1, 0, 0, 24), Parent = head })
	UI.label({ Text = "Final standings · archived " .. UI.timeAgo(a.at or os.time()), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 16), Parent = head })
	local tabs = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = 3, Parent = c }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local i = 0
	for _, s in LC.STATS do
		if s.seasonal then
			i += 1
			chip(tabs, s.icon .. " " .. s.short, state.archiveStat == s.id, s.color, 82, i, function()
				state.archiveStat = s.id
				render()
			end)
		end
	end
	local list = a.boards and a.boards[state.archiveStat] or {}
	if #list == 0 then
		note(c, 4, "Nobody placed on this board that season.")
	end
	for n, e in list do
		row(c, 10 + n, e.rank, e.name, e.text, e.me == true, nil)
	end
end

render = function()
	local c = content
	if not c then
		return
	end
	Phone.clear(c)
	if state.archiveId then
		renderArchive(c)
		return
	end
	local meta = state.meta
	local s = LC.BY_ID[state.stat]

	-- category tabs (horizontal scroller)
	local tabs = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -20, 0, 38),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 2,
		LayoutOrder = 1,
		Parent = c,
	}, { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	for i, st in LC.STATS do
		chip(tabs, st.icon .. " " .. st.short, st.id == state.stat, st.color, 80, i, function()
			selectStat(st.id)
		end)
	end

	-- scope tabs
	local scopes = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = 2, Parent = c }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local seasonOk = s.seasonal and meta and meta.season ~= nil
	local scopeList = { { "all", "All time" } }
	if seasonOk then
		table.insert(scopeList, { "season", "Season" })
	end
	if not s.crew then
		table.insert(scopeList, { "friends", "Friends" })
	end
	local w = math.floor((Phone.width - 20 - 6 * (#scopeList - 1)) / #scopeList)
	for i, sc in scopeList do
		chip(scopes, sc[2], state.scope == sc[1], APP_COLOR, w, i, function()
			if state.scope ~= sc[1] then
				state.scope = sc[1]
				state.board = nil
				render()
				fetchBoard()
			end
		end)
	end

	-- header
	local head = Phone.card(c, 80, 3)
	UI.label({ Text = s.icon .. "  " .. s.label, Font = UI.FONT_BLACK, TextSize = 17, TextColor3 = s.color, Size = UDim2.new(1, 0, 0, 22), Parent = head })
	local sub
	if state.scope == "season" and meta and meta.season then
		sub = meta.season.name .. (if meta.season.endsAt then " · ends " .. os.date("%b %d", meta.season.endsAt) else "")
	elseif state.scope == "friends" then
		sub = "You and your in-game friends"
	else
		sub = "All time"
	end
	local board = if state.boardKey == state.stat .. "|" .. state.scope then state.board else nil
	local where = if board and board.ok then (if board.global then "All servers · " .. ago(board.updatedAt) else "This server (offline boards)") else ""
	UI.label({ Text = sub .. (if where ~= "" then "  ·  " .. where else ""), TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 30), Parent = head })

	if not board then
		note(c, 4, "Loading…")
		return
	end
	if not board.ok then
		note(c, 4, board.msg or "Board unavailable.", colors.danger)
		return
	end

	-- your rank line
	local mine = board.mine
	local meCard = Phone.card(c, 40, 4)
	meCard.BackgroundColor3 = ME_COLOR
	local meText
	if s.crew and not (meta and meta.inCrew) then
		meText = "Join a crew to get on the crew board."
	elseif mine and mine.rank then
		meText = string.format("%s #%d  ·  %s", if s.crew then "Your crew:" else "You:", mine.rank, mine.text)
	elseif mine then
		meText = string.format("%s %s  ·  outside the top %d", if s.crew then "Your crew:" else "You:", mine.text, LC.TOP_N)
	else
		meText = if s.lowerBetter then "No time yet. Finish one to get ranked!" else "Not ranked yet."
	end
	UI.label({ Text = meText, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = Color3.fromRGB(255, 225, 140), Size = UDim2.fromScale(1, 1), Parent = meCard })

	if #board.entries == 0 then
		note(c, 5, if state.scope == "friends" then "None of your friends are on this board yet." else "No entries yet. Be the first!")
	end
	for i, e in board.entries do
		row(c, 10 + i, e.rank, e.name, e.text, e.me == true, e.userId)
	end

	-- archived seasons
	local archives = meta and meta.archives or {}
	if #archives > 0 then
		local h = Phone.card(c, 44 + 36 * math.min(#archives, 6), 200)
		UI.label({ Text = "🏛️  PAST SEASONS", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 20), Parent = h })
		for i, a in archives do
			if i > 6 then
				break
			end
			local b = UI.button({ Text = tostring(a.name), TextSize = 13, BackgroundColor3 = Color3.fromRGB(48, 48, 60), Position = UDim2.fromOffset(0, 24 + (i - 1) * 36), Size = UDim2.new(1, 0, 0, 30), Parent = h })
			b.Activated:Connect(function()
				state.archiveId = a.id
				state.archive = nil
				state.archiveStat = "rating"
				render()
				task.spawn(function()
					local reply = invoke("Archive", a.id)
					if state.archiveId == a.id then
						state.archive = reply or { ok = false, msg = "Couldn't reach the server." }
						render()
					end
				end)
			end)
		end
	end
end

function Leaderboards.start()
	Phone.addApp({ id = APP_ID, label = "Leaders", icon = "🏆", color = APP_COLOR }, function(page: ScrollingFrame)
		content = page
		render()
		return function()
			if state.archiveId == nil then
				fetchMeta()
				fetchBoard()
			end
			render()
		end
	end)
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Remotes")
		remote = folder:WaitForChild("LeaderboardsGet") :: RemoteFunction
	end)
end

return Leaderboards
