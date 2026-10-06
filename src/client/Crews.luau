-- CITY GRIND: crews (sections 60, 61, 62). Client side: the "Crew" phone app.
-- No crew: create form (name, tag, colour, logo), pending invites, leaderboard.
-- In a crew: overview (logo, name, tag, level bar, rep), stats, announcement,
-- weekly crew mission, members with role tools, invites, leaderboard, leave/disband.
-- Every action goes to the server (CrewRequest) which validates and saves it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local CrewsConfig = require(shared:WaitForChild("CrewsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Crews = {}

local CREW_COLOR = Color3.fromRGB(200, 100, 255)
local GOOD = Color3.fromRGB(60, 170, 90)

local CrewRequest: RemoteFunction? = nil
local CrewGet: RemoteFunction? = nil
local gui: ScreenGui? = nil
local invitePopup: Frame
local inviteText: TextLabel
local popupInvite: { crewId: string }? = nil

-- create form state (kept between re-renders)
local form = { name = "", tag = "", color = 6, logo = 1 }
local busy = false
local confirmKey: string? = nil -- the button waiting for a second tap

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function request(action: string, args: any?): boolean
	if not CrewRequest or busy then
		return false
	end
	busy = true
	local ok, result = pcall(function()
		return (CrewRequest :: RemoteFunction):InvokeServer(action, args)
	end)
	busy = false
	if not ok or type(result) ~= "table" then
		HUD.push("CREW", "Couldn't reach the crew service. Try again.")
		return false
	end
	if type(result.message) == "string" and result.message ~= "" then
		HUD.push("CREW", result.message)
	end
	Phone.refresh("Crew")
	return result.ok == true
end

local function fetch(): any
	if not CrewGet then
		return nil
	end
	local ok, result = pcall(function()
		return (CrewGet :: RemoteFunction):InvokeServer()
	end)
	return if ok then result else nil
end

local function formatNumber(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return formatted
end

local function timeLeft(seconds: number): string
	seconds = math.max(0, seconds)
	local d = math.floor(seconds / 86400)
	local h = math.floor((seconds % 86400) / 3600)
	if d > 0 then
		return string.format("%dd %dh left", d, h)
	end
	return string.format("%dh %dm left", h, math.floor((seconds % 3600) / 60))
end

local function myRole(): string
	local r = player:GetAttribute("CrewRole")
	return if type(r) == "string" then r else ""
end

local function canInvite(): boolean
	local r = myRole()
	return r == "Leader" or r == "Officer"
end

-- A button that needs a second tap within 4 s to confirm.
local function confirmButton(props: { [string]: any }, key: string, confirmText: string, fn: () -> ())
	local b = UI.button(props)
	local original = b.Text
	if confirmKey == key then
		b.Text = confirmText
	end
	b.Activated:Connect(function()
		if confirmKey == key then
			confirmKey = nil
			fn()
		else
			confirmKey = key
			b.Text = confirmText
			task.delay(4, function()
				if confirmKey == key then
					confirmKey = nil
					if b.Parent then
						b.Text = original
					end
				end
			end)
		end
	end)
	return b
end

---------------------------------------------------------------------------
-- Phone app
---------------------------------------------------------------------------
local function buildApp(content: ScrollingFrame)
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	local function header(text: string)
		UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = nextOrder(), Parent = content })
	end
	local function note(text: string)
		UI.label({ Text = text, TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 32), LayoutOrder = nextOrder(), Parent = content })
	end

	local function leaderboard(list: { any }, myId: string?)
		header("TOP CREWS")
		if #list == 0 then
			note("No crews on the board yet. Be the first.")
			return
		end
		for i, row in list do
			local c = Phone.card(content, 42, nextOrder())
			if row.id == myId then
				UI.stroke(CREW_COLOR, 1.5, 0.2).Parent = c
			end
			UI.label({ Text = "#" .. i, Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = if i <= 3 then Color3.fromRGB(255, 205, 60) else colors.subtext, Size = UDim2.new(0, 28, 1, 0), Parent = c })
			UI.label({ Text = tostring(row.logo), TextSize = 16, Position = UDim2.fromOffset(28, 0), Size = UDim2.new(0, 22, 1, 0), Parent = c })
			UI.label({
				Text = string.format("[%s] %s", tostring(row.tag), tostring(row.name)),
				Font = UI.FONT_BOLD,
				TextSize = 13,
				TextColor3 = if typeof(row.color) == "Color3" then row.color else colors.text,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Position = UDim2.fromOffset(52, 0),
				Size = UDim2.new(1, -130, 1, 0),
				Parent = c,
			})
			UI.label({ Text = string.format("Lv %d · %s", row.level or 1, formatNumber(row.rep or 0)), TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 80, 1, 0), Parent = c })
		end
	end

	local function renderCreate(snap: any)
		-- pending invites first
		if #snap.invites > 0 then
			header("CREW INVITES")
			for _, inv in snap.invites do
				local c = Phone.card(content, 84, nextOrder())
				UI.label({ Text = string.format("[%s] %s", tostring(inv.tag), tostring(inv.name)), Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), Parent = c })
				UI.label({ Text = "from " .. tostring(inv.by) .. " · " .. UI.timeAgo(inv.at or os.time()), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 14), Parent = c })
				local join = UI.button({ Text = "JOIN", TextSize = 13, BackgroundColor3 = GOOD, Position = UDim2.fromOffset(0, 36), Size = UDim2.new(0.5, -4, 0, 28), Parent = c })
				local decline = UI.button({ Text = "DECLINE", TextSize = 13, Position = UDim2.new(0.5, 4, 0, 36), Size = UDim2.new(0.5, -4, 0, 28), Parent = c })
				join.Activated:Connect(function()
					request("accept", { crewId = inv.crewId })
				end)
				decline.Activated:Connect(function()
					request("decline", { crewId = inv.crewId })
				end)
			end
		end

		header("START A CREW")
		local level = player:GetAttribute("Level") or 1
		local cash = player:GetAttribute("Cash") or 0
		local c = Phone.card(content, 418, nextOrder())
		local reqColor = if level >= snap.minLevel and cash >= snap.fee then colors.subtext else colors.danger
		UI.label({
			Text = string.format("Costs %s · Level %d+ (you: Lv %d, %s)", UI.formatCash(snap.fee), snap.minLevel, level, UI.formatCash(cash)),
			TextSize = 11,
			TextWrapped = true,
			TextColor3 = reqColor,
			Size = UDim2.new(1, 0, 0, 28),
			Parent = c,
		})
		local function box(y: number, placeholder: string, value: string, maxLen: number, onChange: (string) -> ()): TextBox
			local tb = UI.new("TextBox", {
				Text = value,
				PlaceholderText = placeholder,
				ClearTextOnFocus = false,
				Font = UI.FONT,
				TextSize = 14,
				TextColor3 = colors.text,
				PlaceholderColor3 = colors.subtext,
				BackgroundColor3 = Color3.fromRGB(24, 24, 32),
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromOffset(0, y),
				Size = UDim2.new(1, 0, 0, 32),
				Parent = c,
			}, { UI.corner(8), UI.padding(8) })
			tb:GetPropertyChangedSignal("Text"):Connect(function()
				if #tb.Text > maxLen then
					tb.Text = tb.Text:sub(1, maxLen)
				end
				onChange(tb.Text)
			end)
			return tb
		end
		local preview: TextLabel
		local function updatePreview()
			local tag = string.upper(form.tag)
			preview.Text = string.format("%s [%s] %s", CrewsConfig.LOGOS[form.logo], if tag ~= "" then tag else "TAG", if form.name ~= "" then form.name else "Crew name")
			preview.TextColor3 = CrewsConfig.COLORS[form.color].color
		end
		box(32, "Crew name (3-20)", form.name, CrewsConfig.NAME_MAX, function(t)
			form.name = t
			updatePreview()
		end)
		box(70, "Tag (2-4 letters)", form.tag, CrewsConfig.TAG_MAX, function(t)
			form.tag = t
			updatePreview()
		end)
		UI.label({ Text = "COLOUR", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 110), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		local swatches = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 126), Size = UDim2.new(1, 0, 0, 62), Parent = c }, {
			UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(40, 28), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		local swatchButtons = {}
		local function paintSwatches()
			for i, b in swatchButtons do
				local stroke = b:FindFirstChildOfClass("UIStroke") :: UIStroke
				stroke.Transparency = if i == form.color then 0 else 1
			end
		end
		for i, entry in CrewsConfig.COLORS do
			local b = UI.button({ Text = "", BackgroundColor3 = entry.color, LayoutOrder = i, Parent = swatches }, { UI.stroke(Color3.new(1, 1, 1), 2, 1) })
			b.Activated:Connect(function()
				form.color = i
				paintSwatches()
				updatePreview()
			end)
			swatchButtons[i] = b
		end
		UI.label({ Text = "LOGO", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 194), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		local logos = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 210), Size = UDim2.new(1, 0, 0, 76), Parent = c }, {
			UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(34, 34), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		local logoButtons = {}
		local function paintLogos()
			for i, b in logoButtons do
				b.BackgroundColor3 = if i == form.logo then Color3.fromRGB(80, 60, 110) else Color3.fromRGB(24, 24, 32)
			end
		end
		for i, logo in CrewsConfig.LOGOS do
			local b = UI.button({ Text = logo, TextSize = 18, LayoutOrder = i, Parent = logos })
			b.Activated:Connect(function()
				form.logo = i
				paintLogos()
				updatePreview()
			end)
			logoButtons[i] = b
		end
		preview = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 292), Size = UDim2.new(1, 0, 0, 24), Parent = c })
		paintSwatches()
		paintLogos()
		updatePreview()
		UI.label({ Text = "Names and tags are checked by Roblox's filter.", TextSize = 10, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 318), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		local create = UI.button({ Text = "CREATE CREW · " .. UI.formatCash(snap.fee), TextSize = 14, BackgroundColor3 = CREW_COLOR, Position = UDim2.fromOffset(0, 340), Size = UDim2.new(1, 0, 0, 36), Parent = c })
		create.Activated:Connect(function()
			create.Text = "CREATING..."
			if request("create", { name = form.name, tag = form.tag, color = form.color, logo = form.logo }) then
				form.name, form.tag = "", ""
			elseif create.Parent then
				create.Text = "CREATE CREW · " .. UI.formatCash(snap.fee)
			end
		end)
		if not snap.persistent then
			UI.label({ Text = "Crew saving is offline here: crews last until the server closes.", TextSize = 10, TextWrapped = true, TextColor3 = colors.stamina, Position = UDim2.fromOffset(0, 380), Size = UDim2.new(1, 0, 0, 14), Parent = c })
		end
	end

	local function renderCrew(snap: any)
		local crew = snap.crew
		local rank = CrewsConfig.ROLE_RANK
		local me = crew.myRole

		-- Overview
		local o = Phone.card(content, 120, nextOrder())
		UI.stroke(crew.color, 2, 0.3).Parent = o
		UI.label({ Text = tostring(crew.logo), TextSize = 40, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(52, 52), Parent = o })
		UI.label({ Text = crew.name, Font = UI.FONT_BLACK, TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(60, 2), Size = UDim2.new(1, -60, 0, 22), Parent = o })
		UI.label({ Text = "[" .. crew.tag .. "]  ·  " .. me, Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = crew.color, Position = UDim2.fromOffset(60, 26), Size = UDim2.new(1, -60, 0, 16), Parent = o })
		UI.label({ Text = "LEVEL " .. crew.level, Font = UI.FONT_BLACK, TextSize = 13, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(0.5, 0, 0, 16), Parent = o })
		UI.label({
			Text = if crew.levelNext then string.format("%s / %s rep", formatNumber(crew.rep), formatNumber(crew.levelNext)) else formatNumber(crew.rep) .. " rep · MAX",
			TextSize = 11,
			TextColor3 = colors.subtext,
			TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(0.4, 0, 0, 60),
			Size = UDim2.new(0.6, 0, 0, 16),
			Parent = o,
		})
		local _, setFill = UI.bar({ Position = UDim2.fromOffset(0, 80), Size = UDim2.new(1, 0, 0, 10), Parent = o }, crew.color)
		if crew.levelNext then
			setFill((crew.rep - crew.levelFloor) / math.max(1, crew.levelNext - crew.levelFloor))
		else
			setFill(1)
		end

		-- Stats
		local s = Phone.card(content, 56, nextOrder())
		local stats = {
			{ "MEMBERS", crew.memberCount .. "/" .. crew.maxMembers },
			{ "TOTAL WINS", formatNumber(crew.totalWins) },
			{ "FOUNDED", if crew.createdAt > 0 then os.date("!%b %d", crew.createdAt) :: string else "-" },
		}
		for i, pair in stats do
			UI.label({ Text = pair[1], Font = UI.FONT_BLACK, TextSize = 10, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new((i - 1) / 3, 0, 0, 0), Size = UDim2.new(1 / 3, 0, 0, 14), Parent = s })
			UI.label({ Text = pair[2], Font = UI.FONT_BLACK, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new((i - 1) / 3, 0, 0, 14), Size = UDim2.new(1 / 3, 0, 0, 20), Parent = s })
		end

		-- Announcement
		header("ANNOUNCEMENT")
		local ann = crew.announcement
		local canPost = rank[me] and rank[me] >= rank.Officer
		local a = Phone.card(content, if canPost then 142 else 72, nextOrder())
		UI.label({
			Text = if ann then ann.text else "No announcement yet.",
			TextSize = 13,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = if ann then colors.text else colors.subtext,
			Size = UDim2.new(1, 0, 0, 34),
			Parent = a,
		})
		if ann then
			UI.label({ Text = "- " .. tostring(ann.by) .. ", " .. UI.timeAgo(ann.at or os.time()), TextSize = 10, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 14), Parent = a })
		end
		if canPost then
			local tb = UI.new("TextBox", {
				Text = "",
				PlaceholderText = "Write an announcement...",
				ClearTextOnFocus = false,
				MultiLine = false,
				TextWrapped = true,
				Font = UI.FONT,
				TextSize = 13,
				TextColor3 = colors.text,
				PlaceholderColor3 = colors.subtext,
				BackgroundColor3 = Color3.fromRGB(24, 24, 32),
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromOffset(0, 52),
				Size = UDim2.new(1, 0, 0, 34),
				Parent = a,
			}, { UI.corner(8), UI.padding(6) })
			tb:GetPropertyChangedSignal("Text"):Connect(function()
				if #tb.Text > CrewsConfig.ANNOUNCE_MAX then
					tb.Text = tb.Text:sub(1, CrewsConfig.ANNOUNCE_MAX)
				end
			end)
			local post = UI.button({ Text = "POST", TextSize = 13, BackgroundColor3 = CREW_COLOR, Position = UDim2.fromOffset(0, 90), Size = UDim2.new(1, 0, 0, 28), Parent = a })
			post.Activated:Connect(function()
				if tb.Text:match("%S") then
					request("announce", { text = tb.Text })
				end
			end)
		end

		-- Mission
		header("WEEKLY CREW MISSION")
		local mission = crew.mission
		local m = Phone.card(content, 78, nextOrder())
		UI.label({ Text = (if mission.done then "✅ " else "🎯 ") .. mission.title, Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 18), Parent = m })
		local _, setMission = UI.bar({ Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 10), Parent = m }, if mission.done then GOOD else colors.stamina)
		setMission(mission.progress / math.max(1, mission.goal))
		UI.label({ Text = string.format("%s / %s · reward %s crew rep", formatNumber(mission.progress), formatNumber(mission.goal), formatNumber(mission.reward)), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 0, 14), Parent = m })
		UI.label({ Text = timeLeft(mission.endsAt - os.time()), TextSize = 10, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 52), Size = UDim2.new(1, 0, 0, 12), Parent = m })

		-- Members
		header(string.format("MEMBERS  %d/%d", crew.memberCount, crew.maxMembers))
		for _, member in crew.members do
			local isMe = member.userId == player.UserId
			local tools = {}
			if not isMe then
				if me == "Leader" then
					if member.role == "Member" then
						table.insert(tools, { "PROMOTE", "promote", nil })
					elseif member.role == "Officer" then
						table.insert(tools, { "DEMOTE", "demote", nil })
					end
					table.insert(tools, { "LEADER", "transfer", "SURE?" })
					table.insert(tools, { "KICK", "kick", "SURE?" })
				elseif me == "Officer" and member.role == "Member" then
					table.insert(tools, { "KICK", "kick", "SURE?" })
				end
			end
			local c = Phone.card(content, if #tools > 0 then 78 else 46, nextOrder())
			UI.new("Frame", {
				BackgroundColor3 = if member.online then GOOD else Color3.fromRGB(90, 90, 100),
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromOffset(0, 11),
				Size = UDim2.fromOffset(8, 8),
				Parent = c,
			}, { UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
			UI.label({ Text = member.name .. (if isMe then " (you)" else ""), Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(14, 2), Size = UDim2.new(1, -100, 0, 18), Parent = c })
			UI.label({
				Text = member.role .. " · " .. formatNumber(member.wins or 0) .. " W",
				TextSize = 11,
				TextColor3 = if member.role == "Leader" then Color3.fromRGB(255, 205, 60) elseif member.role == "Officer" then crew.color else colors.subtext,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 2),
				Size = UDim2.fromOffset(100, 18),
				Parent = c,
			})
			UI.label({
				Text = if member.here then "Online · this server" elseif member.online then "Online" else ("Last seen " .. UI.timeAgo(if member.seen > 0 then member.seen else os.time())),
				TextSize = 10,
				TextColor3 = colors.subtext,
				Position = UDim2.fromOffset(14, 20),
				Size = UDim2.new(1, -14, 0, 12),
				Parent = c,
			})
			for i, tool in tools do
				local w = 1 / #tools
				local props = {
					Text = tool[1],
					TextSize = 11,
					BackgroundColor3 = if tool[2] == "kick" then colors.danger else Color3.fromRGB(50, 50, 64),
					Position = UDim2.new((i - 1) * w, if i > 1 then 3 else 0, 0, 40),
					Size = UDim2.new(w, -3, 0, 26),
					Parent = c,
				}
				local function run()
					request(tool[2], { userId = member.userId })
				end
				if tool[3] then
					confirmButton(props, tool[2] .. member.userId, tool[3], run)
				else
					UI.button(props).Activated:Connect(run)
				end
			end
		end

		-- Invite people in this server
		if canInvite() then
			header("INVITE PLAYERS IN THIS SERVER")
			local any = false
			for _, other in Players:GetPlayers() do
				local theirCrew = other:GetAttribute("CrewId")
				if other ~= player and (theirCrew == nil or theirCrew == "") and other:GetAttribute("DataLoaded") then
					any = true
					local row = Phone.card(content, 40, nextOrder())
					UI.label({ Text = other.DisplayName, Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -70, 1, 0), Parent = row })
					local inv = UI.button({ Text = "INVITE", TextSize = 12, BackgroundColor3 = CREW_COLOR, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(62, 26), Parent = row })
					inv.Activated:Connect(function()
						inv.Text = "..."
						if not request("invite", { target = other }) and inv.Parent then
							inv.Text = "INVITE"
						end
					end)
				end
			end
			if not any then
				note("Everyone here is already in a crew.")
			end
		end

		leaderboard(snap.leaderboard, crew.id)

		-- Leave / disband
		local f = Phone.card(content, 36, nextOrder())
		f.BackgroundTransparency = 1
		if me == "Leader" then
			confirmButton({ Text = "LEAVE", TextSize = 13, BackgroundColor3 = colors.danger, Size = UDim2.new(0.5, -4, 1, 0), Parent = f }, "leave", "TAP AGAIN", function()
				request("leave")
			end)
			confirmButton({ Text = "DISBAND CREW", TextSize = 13, BackgroundColor3 = Color3.fromRGB(120, 40, 40), Position = UDim2.new(0.5, 4, 0, 0), Size = UDim2.new(0.5, -4, 1, 0), Parent = f }, "disband", "DISBAND?", function()
				request("disband")
			end)
		else
			confirmButton({ Text = "LEAVE CREW", TextSize = 13, BackgroundColor3 = colors.danger, Size = UDim2.fromScale(1, 1), Parent = f }, "leave", "TAP AGAIN TO LEAVE", function()
				request("leave")
			end)
		end
	end

	local renderToken = 0
	local function render()
		renderToken += 1
		local token = renderToken
		local snap = fetch()
		if snap == nil then
			-- the server rate-limits reads; ask again in a moment
			task.wait(0.6)
			if token ~= renderToken then
				return
			end
			snap = fetch()
		end
		if token ~= renderToken then
			return -- a newer refresh is on its way
		end
		Phone.clear(content)
		order = 0
		if type(snap) ~= "table" or not snap.loaded then
			note("Loading your crew...")
			return
		end
		if snap.crew then
			renderCrew(snap)
		else
			renderCreate(snap)
			leaderboard(snap.leaderboard, nil)
		end
	end
	return render
end

---------------------------------------------------------------------------
-- Invite prompt (used when there's no Messages app)
---------------------------------------------------------------------------
local function buildPopup()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindCrews",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 6,
		Parent = player:WaitForChild("PlayerGui"),
	})
	invitePopup = UI.new("Frame", {
		Name = "CrewInvite",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -350),
		Size = UDim2.fromOffset(330, 92),
		BackgroundColor3 = colors.panel,
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.stroke(CREW_COLOR, 1.5, 0.2), UI.padding(10) })
	inviteText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 14, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 34), Parent = invitePopup })
	local yes = UI.button({ Text = "JOIN CREW", TextSize = 14, BackgroundColor3 = GOOD, Position = UDim2.new(0, 0, 1, -34), Size = UDim2.new(0.5, -4, 0, 34), Parent = invitePopup })
	local later = UI.button({ Text = "LATER", TextSize = 14, Position = UDim2.new(0.5, 4, 1, -34), Size = UDim2.new(0.5, -4, 0, 34), Parent = invitePopup })
	yes.Activated:Connect(function()
		local inv = popupInvite
		popupInvite = nil
		invitePopup.Visible = false
		if inv then
			request("accept", { crewId = inv.crewId })
		end
	end)
	later.Activated:Connect(function()
		-- the invite stays in the Crew app for a few days
		popupInvite = nil
		invitePopup.Visible = false
	end)
end

local function showInvite(data: any)
	if type(data) ~= "table" or type(data.crewId) ~= "string" then
		return
	end
	popupInvite = { crewId = data.crewId }
	inviteText.Text = string.format("🛡️ %s invited you to [%s] %s", tostring(data.by), tostring(data.tag), tostring(data.name))
	invitePopup.Visible = true
	local mine = popupInvite
	task.delay(45, function()
		if popupInvite == mine then
			popupInvite = nil
			invitePopup.Visible = false
		end
	end)
end

---------------------------------------------------------------------------
-- Social menu
---------------------------------------------------------------------------
local function addMenuActions()
	local module = script.Parent:FindFirstChild("Social")
	if not module then
		return
	end
	local ok, Social = pcall(require, module)
	if not ok or type(Social) ~= "table" or type(Social.addMenuAction) ~= "function" then
		return
	end
	Social.addMenuAction({
		id = "CrewInvite",
		label = "INVITE TO CREW",
		order = 21,
		visible = function(target: Player)
			local theirs = target:GetAttribute("CrewId")
			return canInvite() and (theirs == nil or theirs == "")
		end,
		run = function(target: Player)
			task.spawn(request, "invite", { target = target })
		end,
	})
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Crews.start()
	Phone.addApp({ id = "Crew", label = "Crew", icon = "🛡️", color = CREW_COLOR }, function(content)
		return buildApp(content)
	end)

	task.spawn(function()
		buildPopup()
		local remotes = shared:WaitForChild("Remotes")
		CrewRequest = remotes:WaitForChild("CrewRequest") :: RemoteFunction
		CrewGet = remotes:WaitForChild("CrewGet") :: RemoteFunction
		local CrewEvent = remotes:WaitForChild("CrewEvent") :: RemoteEvent
		CrewEvent.OnClientEvent:Connect(function(kind: any, data: any)
			if kind == "changed" then
				Phone.refresh("Crew")
			elseif kind == "invite" then
				showInvite(data)
				Phone.refresh("Crew")
			end
		end)
	end)

	task.spawn(addMenuActions)
end

return Crews
