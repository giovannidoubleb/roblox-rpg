-- CITY GRIND: the phone's Messages app (sections 17, 18, 36, 46, 48, 109).
-- Conversation list, chat bubbles, emoji quick-picker, invite cards with
-- ACCEPT / DECLINE, group chats (create, rename, members, mute, leave) and
-- Contacts. Everything is decided by the server (Messages.luau): this module
-- only shows what it's sent and asks it to do things. Blocked / muted players'
-- messages are hidden here too (Social.isBlocked / Social.isMuted).
-- Also adds SEND MESSAGE / INVITE TO BASKETBALL / INVITE TO MY PLACE to the
-- player interaction menu (Social.addMenuAction).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("MessagesConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Messages = {}

local APP_ID = "Messages"
local BLUE = Color3.fromRGB(40, 130, 255)
local GREEN = Color3.fromRGB(60, 190, 100)
local BUBBLE_MAX = 178

local Request: RemoteFunction? = nil
local convos: { [string]: any } = {} -- conversation id -> summary from the server

-- UI state
local content: ScrollingFrame -- the app's scrolling list (list / contacts / pickers / settings)
local appFrame: Frame
local chatView: Frame
local chatTitle: TextLabel
local chatAction: TextButton
local chatDelete: TextButton
local msgList: ScrollingFrame
local composer: Frame
local readOnlyNote: TextLabel
local input: TextBox
local banner: TextLabel
local view = "list" -- list | contacts | new | newgroup | chat | settings | add
local currentId: string? = nil
local currentSummary: any = nil
local currentMsgs: { any } = {}
local inviteCards: { [string]: (string) -> () } = {}
local pendingChat: string? = nil
local iconBadge: TextLabel? = nil
local renderQueued = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local socialModule: any = nil
local function social(): any?
	if socialModule == nil then
		local m = script.Parent:FindFirstChild("Social")
		if not m then
			return nil
		end
		local ok, result = pcall(require, m)
		socialModule = if ok then result else false
	end
	return socialModule or nil
end

-- Hidden = you blocked/muted them or they blocked you.
local function hidden(userId: number?): boolean
	if not userId or userId == 0 or userId == player.UserId then
		return false
	end
	local S = social()
	if not S then
		return false
	end
	for _, fnName in { "isBlocked", "isMuted" } do
		local fn = S[fnName]
		if type(fn) == "function" then
			local ok, result = pcall(fn, userId)
			if ok and result then
				return true
			end
		end
	end
	return false
end

local function request(action: string, payload: any?): (boolean, string?, any)
	if not Request then
		return false, "Messages are still loading.", nil
	end
	local ok, success, message, result = pcall(function()
		return (Request :: RemoteFunction):InvokeServer(action, payload)
	end)
	if not ok then
		return false, "Couldn't reach the server.", nil
	end
	return success == true, message, result
end

-- Short feedback: a banner in the app when it's on screen, otherwise a notification.
local function say(text: string?)
	if not text or text == "" then
		return
	end
	if banner and Phone.isOpen() and Phone.currentPage() == APP_ID then
		banner.Text = text
		banner.Visible = true
		local stamp = os.clock()
		banner:SetAttribute("Stamp", stamp)
		task.delay(3, function()
			if banner:GetAttribute("Stamp") == stamp then
				banner.Visible = false
			end
		end)
	else
		HUD.push("MESSAGES", text)
	end
end

local function textHeight(text: string, size: number, width: number, font: Enum.Font?): Vector2
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, font or UI.FONT, Vector2.new(width, 10000))
	end)
	return if ok then bounds else Vector2.new(width, size * 2)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function ago(t: number): string
	local diff = math.max(0, serverNow() - t)
	if diff < 60 then
		return "now"
	elseif diff < 3600 then
		return math.floor(diff / 60) .. "m"
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h"
	end
	return math.floor(diff / 86400) .. "d"
end

local function limitBox(box: TextBox, maxChars: number)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text
		local length = utf8.len(text)
		if length and length > maxChars then
			box.Text = text:sub(1, (utf8.offset(text, maxChars + 1) or (#text + 1)) - 1)
		end
	end)
end

local function smallButton(parent: Instance, text: string, color: Color3, x: UDim, y: number, w: number, h: number): TextButton
	return UI.button({ Text = text, TextSize = 12, BackgroundColor3 = color, Position = UDim2.new(x, UDim.new(0, y)), Size = UDim2.fromOffset(w, h), Parent = parent })
end

local function totalUnread(): number
	local n = 0
	for _, c in convos do
		if not c.muted and not (c.kind == "dm" and hidden(c.with)) then
			n += c.unread or 0
		end
	end
	return n
end

local function updateBadge()
	if iconBadge then
		local n = totalUnread()
		iconBadge.Visible = n > 0
		iconBadge.Text = if n > 9 then "9+" else tostring(n)
	end
end

local function header(order: number, text: string, back: (() -> ())?)
	local row = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = order, Parent = content })
	if back then
		local b = UI.button({ Text = "‹ Back", TextSize = 14, BackgroundTransparency = 1, TextColor3 = colors.xp, Size = UDim2.fromOffset(60, 30), Parent = row })
		b.Activated:Connect(back)
	end
	UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromScale(1, 1), Parent = row })
end

local function iconCircle(parent: Instance, emoji: string, color: Color3, size: number)
	return UI.label({ Text = emoji, TextSize = math.floor(size * 0.55), TextXAlignment = Enum.TextXAlignment.Center, BackgroundTransparency = 0, BackgroundColor3 = color, Size = UDim2.fromOffset(size, size), Parent = parent }, { UI.corner(math.floor(size / 2)) })
end

---------------------------------------------------------------------------
-- Views (forward declared)
---------------------------------------------------------------------------
local showList: () -> ()
local openChat: (string) -> ()
local showSettings: (string, any?) -> ()

local function showContentView(name: string)
	view = name
	chatView.Visible = false
	content.Visible = true
	Phone.clear(content)
	content.CanvasPosition = Vector2.zero
end

-- Conversation list
showList = function()
	showContentView("list")
	currentId = nil
	local tabs = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 32), LayoutOrder = 1, Parent = content }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local function tab(text: string, order: number, color: Color3, fn: () -> ())
		local b = UI.button({ Text = text, TextSize = 12, BackgroundColor3 = color, Size = UDim2.new(0.25, -5, 1, 0), LayoutOrder = order, Parent = tabs })
		b.Activated:Connect(fn)
	end
	tab("CHATS", 1, colors.accent, showList)
	tab("CONTACTS", 2, colors.panelLight, function()
		Messages.showContacts()
	end)
	tab("+ NEW", 3, BLUE, function()
		Messages.showPicker()
	end)
	tab("+ GROUP", 4, GREEN, function()
		Messages.showNewGroup()
	end)

	local list = {}
	for _, c in convos do
		if not (c.kind == "dm" and hidden(c.with)) then
			table.insert(list, c)
		end
	end
	table.sort(list, function(a, b)
		return (a.t or 0) > (b.t or 0)
	end)
	if #list == 0 then
		UI.label({ Text = "No messages yet.\nTap + NEW to text someone, or + GROUP to start a group chat.", TextWrapped = true, TextColor3 = colors.subtext, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -30, 0, 60), LayoutOrder = 2, Parent = content })
	end
	for i, c in list do
		local row = UI.new("TextButton", {
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = colors.panelLight,
			Size = UDim2.new(1, -20, 0, 58),
			LayoutOrder = 10 + i,
			Parent = content,
		}, { UI.corner(14) })
		local circle = iconCircle(row, c.icon or "💬", c.color or BLUE, 38)
		circle.Position = UDim2.fromOffset(10, 10)
		local unread = c.unread or 0
		UI.label({ Text = c.title or "Chat", Font = if unread > 0 then UI.FONT_BLACK else UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(56, 9), Size = UDim2.new(1, -110, 0, 18), Parent = row })
		UI.label({ Text = (if c.muted then "🔕 " else "") .. (c.preview or ""), TextSize = 12, TextColor3 = if unread > 0 then colors.text else colors.subtext, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(56, 30), Size = UDim2.new(1, -96, 0, 16), Parent = row })
		UI.label({ Text = if (c.t or 0) > 0 then ago(c.t) else "", TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(40, 14), Parent = row })
		if unread > 0 then
			UI.label({ Text = if unread > 9 then "9+" else tostring(unread), Font = UI.FONT_BLACK, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, BackgroundTransparency = 0, BackgroundColor3 = if c.muted then colors.subtext else Color3.fromRGB(255, 50, 50), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 30), Size = UDim2.fromOffset(20, 18), Parent = row }, { UI.corner(9) })
		end
		row.Activated:Connect(function()
			openChat(c.id)
		end)
	end
	updateBadge()
end

local function queueRender()
	if renderQueued then
		return
	end
	renderQueued = true
	task.defer(function()
		renderQueued = false
		if Phone.isOpen() and Phone.currentPage() == APP_ID and view == "list" then
			showList()
		end
		updateBadge()
	end)
end

-- Contacts (friends + online status)
function Messages.showContacts()
	showContentView("contacts")
	header(1, "CONTACTS", showList)
	local loading = UI.label({ Text = "Loading...", TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 2, Parent = content })
	local ok, message, list = request("Contacts")
	if view ~= "contacts" then
		return
	end
	loading:Destroy()
	if not ok or type(list) ~= "table" then
		say(message or "Couldn't load contacts.")
		return
	end
	if #list == 0 then
		UI.label({ Text = "No friends yet. Open a player's menu (click them) and tap ADD FRIEND.", TextWrapped = true, TextColor3 = colors.subtext, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -30, 0, 50), LayoutOrder = 2, Parent = content })
	end
	local rank = { here = 1, online = 2, offline = 3 }
	table.sort(list, function(a, b)
		if rank[a.status] ~= rank[b.status] then
			return (rank[a.status] or 4) < (rank[b.status] or 4)
		end
		return tostring(a.name) < tostring(b.name)
	end)
	for i, c in list do
		local row = Phone.card(content, 52, 10 + i)
		UI.label({ Text = c.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -110, 0, 16), Parent = row })
		local statusText, statusColor = "Offline", colors.subtext
		if c.status == "here" then
			statusText, statusColor = "● In this server", colors.cash
		elseif c.status == "online" then
			statusText, statusColor = "● Online", colors.xp
		end
		UI.label({ Text = statusText, TextSize = 11, TextColor3 = statusColor, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -110, 0, 14), Parent = row })
		local text = smallButton(row, "TEXT", BLUE, UDim.new(1, -104), 0, 50, 28)
		text.Activated:Connect(function()
			openChat("d" .. c.id)
		end)
		local S = social()
		if S and type(S.openProfile) == "function" then
			local profile = smallButton(row, "👤", colors.panel, UDim.new(1, -48), 0, 48, 28)
			profile.Activated:Connect(function()
				pcall(S.openProfile, c.id)
			end)
		end
	end
end

-- Pick someone to text (friends + players here)
function Messages.showPicker()
	showContentView("new")
	header(1, "NEW MESSAGE", showList)
	local ok, message, list = request("Pick")
	if view ~= "new" then
		return
	end
	if not ok or type(list) ~= "table" then
		say(message or "Couldn't load people.")
		return
	end
	if #list == 0 then
		UI.label({ Text = "Nobody to text yet. Make some friends around the city!", TextWrapped = true, TextColor3 = colors.subtext, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -30, 0, 40), LayoutOrder = 2, Parent = content })
	end
	for i, c in list do
		if not hidden(c.id) then
			local row = UI.new("TextButton", { Text = "", BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, -20, 0, 44), LayoutOrder = 10 + i, Parent = content }, { UI.corner(12), UI.padding(10) })
			UI.label({ Text = c.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -100, 1, 0), Parent = row })
			UI.label({
				Text = (if c.friend then "Friend · " else "") .. (if c.status == "here" then "Here" elseif c.status == "online" then "Online" else "Offline"),
				TextSize = 11,
				TextColor3 = if c.status == "offline" then colors.subtext else colors.cash,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, 100, 1, 0),
				Parent = row,
			})
			row.Activated:Connect(function()
				openChat("d" .. c.id)
			end)
		end
	end
end

-- Checklist of people (for new group / add members). Returns the selected set.
local function peopleChecklist(list: { any }, startOrder: number, exclude: { [number]: boolean }): { [number]: boolean }
	local selected: { [number]: boolean } = {}
	local shown = 0
	for i, c in list do
		if not exclude[c.id] and not hidden(c.id) then
			shown += 1
			local row = UI.new("TextButton", { Text = "", BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, -20, 0, 40), LayoutOrder = startOrder + i, Parent = content }, { UI.corner(12), UI.padding(10) })
			local box = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center, BackgroundTransparency = 0, BackgroundColor3 = colors.panel, Size = UDim2.fromOffset(20, 20), Parent = row }, { UI.corner(6) })
			UI.label({ Text = c.name .. (if c.status == "here" then "  · here" else ""), TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -30, 1, 0), Parent = row })
			row.Activated:Connect(function()
				selected[c.id] = if selected[c.id] then nil else true :: any
				box.Text = if selected[c.id] then "✓" else ""
				box.BackgroundColor3 = if selected[c.id] then GREEN else colors.panel
			end)
		end
	end
	if shown == 0 then
		UI.label({ Text = "No friends or players here to add.", TextColor3 = colors.subtext, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -30, 0, 30), LayoutOrder = startOrder + 1, Parent = content })
	end
	return selected
end

local function selectedIds(set: { [number]: boolean }): { number }
	local ids = {}
	for id in set do
		table.insert(ids, id)
	end
	return ids
end

-- Icon + colour pickers. onPick(iconIndex?, colorIndex?)
local function stylePickers(order: number, icon: number, color: number, onPick: (number?, number?) -> ())
	local iconCard = Phone.card(content, 80, order)
	UI.label({ Text = "ICON", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = iconCard })
	local iconRow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 1, -16), Parent = iconCard }, {
		UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(32, 22), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local iconButtons = {}
	for i, emoji in Cfg.GROUP_ICONS do
		local b = UI.button({ Text = emoji, TextSize = 14, Font = UI.FONT, BackgroundColor3 = if i == icon then colors.accent else colors.panel, LayoutOrder = i, Parent = iconRow })
		iconButtons[i] = b
		b.Activated:Connect(function()
			for j, other in iconButtons do
				other.BackgroundColor3 = if j == i then colors.accent else colors.panel
			end
			onPick(i, nil)
		end)
	end
	local colorCard = Phone.card(content, 52, order + 1)
	UI.label({ Text = "COLOR", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = colorCard })
	local colorRow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 22), Parent = colorCard }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local swatches = {}
	for i, c in Cfg.GROUP_COLORS do
		local b = UI.button({ Text = if i == color then "✓" else "", TextSize = 13, BackgroundColor3 = c, Size = UDim2.fromOffset(24, 22), LayoutOrder = i, Parent = colorRow })
		swatches[i] = b
		b.Activated:Connect(function()
			for j, other in swatches do
				other.Text = if j == i then "✓" else ""
			end
			onPick(nil, i)
		end)
	end
end

local function textField(parent: Instance, placeholder: string, maxChars: number, y: number, width: UDim): TextBox
	local box = UI.new("TextBox", {
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = colors.subtext,
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = colors.panel,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(width, UDim.new(0, 30)),
		Parent = parent,
	}, { UI.corner(8), UI.padding(6) })
	limitBox(box, maxChars)
	return box
end

-- New group: name, icon, colour, members
function Messages.showNewGroup()
	showContentView("newgroup")
	header(1, "NEW GROUP", showList)
	local nameCard = Phone.card(content, 58, 2)
	UI.label({ Text = "GROUP NAME", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = nameCard })
	local nameBox = textField(nameCard, "e.g. Court Squad", Cfg.GROUP_NAME_MAX, 16, UDim.new(1, 0))
	local icon, color = 1, 1
	stylePickers(3, icon, color, function(i, c)
		icon = i or icon
		color = c or color
	end)
	UI.label({ Text = "MEMBERS (up to " .. (Cfg.GROUP_MAX_MEMBERS - 1) .. ")", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 14), LayoutOrder = 6, Parent = content })
	local create = UI.button({ Text = "CREATE GROUP", TextSize = 14, BackgroundColor3 = GREEN, Size = UDim2.new(1, -20, 0, 38), LayoutOrder = 900, Parent = content })
	local ok, message, list = request("Pick")
	if view ~= "newgroup" then
		return
	end
	if not ok or type(list) ~= "table" then
		say(message or "Couldn't load people.")
		list = {}
	end
	local selected = peopleChecklist(list, 10, {})
	local busy = false
	create.Activated:Connect(function()
		if busy then
			return
		end
		local ids = selectedIds(selected)
		if #ids == 0 then
			say("Pick at least one person.")
			return
		end
		if nameBox.Text:match("^%s*$") then
			say("Give the group a name.")
			return
		end
		busy = true
		create.Text = "CREATING..."
		local okCreate, msg, summary = request("CreateGroup", { name = nameBox.Text, icon = icon, color = color, members = ids })
		busy = false
		create.Text = "CREATE GROUP"
		if okCreate and type(summary) == "table" then
			convos[summary.id] = summary
			openChat(summary.id)
		else
			say(msg or "Couldn't create the group.")
		end
	end)
end

-- Group settings
showSettings = function(gid: string, info: any?)
	showContentView("settings")
	header(1, "GROUP SETTINGS", function()
		openChat(gid)
	end)
	if not info then
		local ok, message, result = request("Group", { id = gid, cmd = "Info" })
		if view ~= "settings" then
			return
		end
		if not ok then
			say(message or "Couldn't load the group.")
			return
		end
		info = result
	end
	if type(info) ~= "table" then
		return
	end
	local admin = info.myRole == "owner" or info.myRole == "admin"
	local function run(cmd: string, extra: { [string]: any }?)
		local payload = extra or {}
		payload.id = gid
		payload.cmd = cmd
		local ok, message, result = request("Group", payload)
		say(message)
		if ok and type(result) == "table" and view == "settings" then
			showSettings(gid, result)
		end
		return ok
	end

	local top = Phone.card(content, 64, 2)
	local circle = iconCircle(top, Cfg.GROUP_ICONS[info.icon] or "💬", Cfg.GROUP_COLORS[info.color] or BLUE, 40)
	circle.Position = UDim2.fromOffset(0, 0)
	UI.label({ Text = info.name, Font = UI.FONT_BLACK, TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(48, 2), Size = UDim2.new(1, -48, 0, 18), Parent = top })
	UI.label({ Text = #info.members .. "/" .. Cfg.GROUP_MAX_MEMBERS .. " members · you're " .. tostring(info.myRole), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(48, 22), Size = UDim2.new(1, -48, 0, 14), Parent = top })

	local muteCard = Phone.card(content, 46, 3)
	UI.label({ Text = if info.muted then "🔕 Notifications off" else "🔔 Notifications on", TextSize = 13, Size = UDim2.new(1, -80, 1, 0), Parent = muteCard })
	local mute = smallButton(muteCard, if info.muted then "UNMUTE" else "MUTE", colors.panel, UDim.new(1, -76), -3, 76, 28)
	mute.Activated:Connect(function()
		run("Mute", { on = not info.muted })
	end)

	if admin then
		local renameCard = Phone.card(content, 58, 4)
		UI.label({ Text = "RENAME", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = renameCard })
		local box = textField(renameCard, info.name, Cfg.GROUP_NAME_MAX, 16, UDim.new(1, -64))
		local save = smallButton(renameCard, "SAVE", BLUE, UDim.new(1, -58), 16, 58, 30)
		save.Activated:Connect(function()
			if not box.Text:match("^%s*$") then
				run("Rename", { name = box.Text })
			end
		end)
		stylePickers(5, info.icon, info.color, function(i, c)
			run("Style", { icon = i, color = c })
		end)
	end

	UI.label({ Text = "MEMBERS", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 14), LayoutOrder = 10, Parent = content })
	local roleRank = { owner = 1, admin = 2, member = 3 }
	table.sort(info.members, function(a, b)
		if a.role ~= b.role then
			return (roleRank[a.role] or 4) < (roleRank[b.role] or 4)
		end
		return tostring(a.name) < tostring(b.name)
	end)
	for i, m in info.members do
		local row = Phone.card(content, 44, 10 + i)
		local me = m.id == player.UserId
		UI.label({ Text = m.name .. (if me then " (you)" else ""), Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -120, 0, 16), Parent = row })
		UI.label({ Text = (if m.role == "owner" then "👑 Owner" elseif m.role == "admin" then "⭐ Admin" else "Member") .. (if m.here then " · here" else ""), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -120, 0, 12), Parent = row })
		if not me and m.role ~= "owner" then
			if info.myRole == "owner" then
				local promote = smallButton(row, if m.role == "admin" then "UNADMIN" else "ADMIN", colors.panel, UDim.new(1, -118), -2, 58, 24)
				promote.Activated:Connect(function()
					run("Admin", { userId = m.id, on = m.role ~= "admin" })
				end)
			end
			if admin and (m.role == "member" or info.myRole == "owner") then
				local remove = smallButton(row, "REMOVE", colors.danger, UDim.new(1, -58), -2, 58, 24)
				remove.Activated:Connect(function()
					run("Remove", { userId = m.id })
				end)
			end
		end
	end

	if admin and #info.members < Cfg.GROUP_MAX_MEMBERS then
		local add = UI.button({ Text = "+ ADD PEOPLE", TextSize = 13, BackgroundColor3 = GREEN, Size = UDim2.new(1, -20, 0, 36), LayoutOrder = 200, Parent = content })
		add.Activated:Connect(function()
			Messages.showAddMembers(gid, info)
		end)
	end
	local leave = UI.button({ Text = "LEAVE GROUP", TextSize = 13, BackgroundColor3 = colors.danger, Size = UDim2.new(1, -20, 0, 36), LayoutOrder = 201, Parent = content })
	local armed = false
	leave.Activated:Connect(function()
		if not armed then
			armed = true
			leave.Text = "TAP AGAIN TO LEAVE"
			task.delay(3, function()
				armed = false
				if leave.Parent then
					leave.Text = "LEAVE GROUP"
				end
			end)
			return
		end
		local ok, message = request("Group", { id = gid, cmd = "Leave" })
		say(message)
		if ok then
			convos[gid] = nil
			showList()
		end
	end)
end

function Messages.showAddMembers(gid: string, info: any)
	showContentView("add")
	header(1, "ADD PEOPLE", function()
		showSettings(gid, info)
	end)
	local add = UI.button({ Text = "ADD TO GROUP", TextSize = 14, BackgroundColor3 = GREEN, Size = UDim2.new(1, -20, 0, 38), LayoutOrder = 900, Parent = content })
	local ok, message, list = request("Pick")
	if view ~= "add" then
		return
	end
	if not ok or type(list) ~= "table" then
		say(message or "Couldn't load people.")
		list = {}
	end
	local exclude = {}
	for _, m in info.members do
		exclude[m.id] = true
	end
	local selected = peopleChecklist(list, 10, exclude)
	add.Activated:Connect(function()
		local ids = selectedIds(selected)
		if #ids == 0 then
			say("Pick at least one person.")
			return
		end
		local okAdd, msg, result = request("Group", { id = gid, cmd = "Add", userIds = ids })
		say(msg or (if okAdd then "Added." else nil))
		if okAdd then
			showSettings(gid, result)
		end
	end)
end

---------------------------------------------------------------------------
-- Chat view
---------------------------------------------------------------------------
local function scrollToBottom()
	task.defer(function()
		msgList.CanvasPosition = Vector2.new(0, math.max(0, msgList.AbsoluteCanvasSize.Y - msgList.AbsoluteWindowSize.Y))
	end)
end

local function inviteCard(row: Frame, msg: any, mine: boolean): number
	local inv = msg.invite
	local style = Cfg.INVITE_STYLE[inv.kind] or Cfg.INVITE_STYLE.event
	local forMe = inv.to == player.UserId
	local cardFrame = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(if mine then 1 else 0, 0),
		Position = UDim2.fromScale(if mine then 1 else 0, 0),
		Size = UDim2.fromOffset(206, 104),
		Parent = row,
	}, { UI.corner(14), UI.stroke(style.color, 1.5), UI.padding(10) })
	UI.label({ Text = inv.icon .. "  " .. inv.title, Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = style.color, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 16), Parent = cardFrame })
	UI.label({ Text = (if mine then "You invited them" else msg.name .. " invited you") .. (if inv.sub then " · " .. inv.sub else ""), TextSize = 11, TextColor3 = colors.subtext, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 14), Parent = cardFrame })
	local status = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 12, Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 14), Parent = cardFrame })
	local accept = smallButton(cardFrame, "ACCEPT", GREEN, UDim.new(0, 0), 54, 88, 30)
	local decline = smallButton(cardFrame, "DECLINE", colors.danger, UDim.new(0.5, 4), 54, 88, 30)
	local current = inv.state

	local function update(state: string)
		current = state
		inv.state = state
		local expired = state == "pending" and serverNow() > inv.expires
		local open = state == "pending" and not expired
		accept.Visible = open and forMe
		decline.Visible = open and forMe
		if state == "accepted" then
			status.Text, status.TextColor3 = "✅ Accepted", colors.cash
		elseif state == "declined" then
			status.Text, status.TextColor3 = "Declined", colors.subtext
		elseif not open then
			status.Text, status.TextColor3 = "Expired", colors.subtext
		elseif forMe then
			status.Text, status.TextColor3 = "Expires in " .. math.max(1, math.ceil((inv.expires - serverNow()) / 60)) .. " min", colors.text
		else
			status.Text, status.TextColor3 = "Waiting for a reply…", colors.text
		end
		cardFrame.Size = UDim2.fromOffset(206, if open and forMe then 104 else 70)
	end
	update(current)
	inviteCards[msg.id] = update

	local busy = false
	local function answer(yes: boolean)
		if busy then
			return
		end
		busy = true
		local ok, message = request("Respond", { id = inv.id, accept = yes })
		busy = false
		say(message or (if ok then nil else "That didn't work."))
	end
	accept.Activated:Connect(function()
		answer(true)
	end)
	decline.Activated:Connect(function()
		answer(false)
	end)
	-- keep the countdown honest while it's on screen
	task.spawn(function()
		while cardFrame.Parent and current == "pending" do
			task.wait(20)
			if cardFrame.Parent and current == "pending" then
				update(current)
			end
		end
	end)
	return if inv.state == "pending" and forMe then 104 else 70
end

local nextOrder = 0
local function renderMsg(msg: any)
	if msg.from ~= player.UserId and hidden(msg.from) then
		return
	end
	nextOrder += 1
	local mine = msg.from == player.UserId
	local row = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -16, 0, 20), LayoutOrder = nextOrder, Parent = msgList })

	if msg.kind == "system" and (not currentSummary or currentSummary.kind == "group") then
		-- group notices ("X joined") are centred grey lines
		local bounds = textHeight(msg.text, 11, 220)
		UI.label({ Text = msg.text, TextWrapped = true, TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, bounds.Y + 4), Parent = row })
		row.Size = UDim2.new(1, -16, 0, bounds.Y + 6)
		return
	end
	if msg.kind == "invite" and msg.invite then
		local h = inviteCard(row, msg, mine)
		row.Size = UDim2.new(1, -16, 0, h)
		return
	end

	local showName = not mine and currentSummary and currentSummary.kind == "group"
	local text = tostring(msg.text)
	local bounds = textHeight(text, 14, BUBBLE_MAX)
	local w, h = math.max(bounds.X + 4, 24), bounds.Y + 2
	local y = 0
	if showName then
		UI.label({ Text = msg.name, Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(4, 0), Size = UDim2.new(1, 0, 0, 13), Parent = row })
		y = 14
	end
	local bubble = UI.new("Frame", {
		BackgroundColor3 = if mine then BLUE elseif msg.kind == "system" then Color3.fromRGB(70, 50, 30) else colors.panelLight,
		AnchorPoint = Vector2.new(if mine then 1 else 0, 0),
		Position = UDim2.new(if mine then 1 else 0, 0, 0, y),
		Size = UDim2.fromOffset(w + 20, h + 14),
		Parent = row,
	}, { UI.corner(14) })
	UI.label({ Text = text, TextWrapped = true, TextSize = 14, Position = UDim2.fromOffset(10, 7), Size = UDim2.fromOffset(w + 2, h), Parent = bubble })
	UI.label({ Text = ago(msg.t), TextSize = 10, TextColor3 = colors.subtext, TextXAlignment = if mine then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left, Position = UDim2.fromOffset(4, y + h + 15), Size = UDim2.new(1, -8, 0, 11), Parent = row })
	row.Size = UDim2.new(1, -16, 0, y + h + 28)
end

local function renderChat()
	Phone.clear(msgList)
	table.clear(inviteCards)
	nextOrder = 0
	for _, msg in currentMsgs do
		renderMsg(msg)
	end
	if #currentMsgs == 0 then
		nextOrder += 1
		UI.label({ Text = "Say what's up 👋", TextColor3 = colors.subtext, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 0, Name = "Empty", Parent = msgList })
	end
	scrollToBottom()
end

local function setChatHeader(summary: any)
	currentSummary = summary
	chatTitle.Text = (summary.icon or "💬") .. "  " .. (summary.title or "Chat")
	local canReply = summary.canReply ~= false
	composer.Visible = canReply
	readOnlyNote.Visible = not canReply
	readOnlyNote.Text = (summary.title or "They") .. " can't get replies here."
	msgList.Size = UDim2.new(1, 0, 1, if canReply then -114 else -66)
	chatAction.Visible = summary.kind == "group" or (summary.kind == "dm" and social() ~= nil)
	chatAction.Text = if summary.kind == "group" then "⚙" else "👤"
	chatDelete.Visible = summary.kind ~= "group"
	chatDelete.Text = "🗑"
end

openChat = function(convId: string)
	pendingChat = nil
	view = "chat"
	content.Visible = false
	chatView.Visible = true
	currentId = convId
	currentMsgs = {}
	local cached = convos[convId]
	if cached then
		setChatHeader(cached)
	else
		setChatHeader({ id = convId, kind = "dm", title = "...", icon = "👤", canReply = true })
	end
	Phone.clear(msgList)
	local ok, message, result = request("Open", convId)
	if currentId ~= convId or view ~= "chat" then
		return
	end
	if not ok or type(result) ~= "table" then
		say(message or "Couldn't open that chat.")
		showList()
		return
	end
	if result.summary then
		if convos[convId] then
			convos[convId] = result.summary
		end
		setChatHeader(result.summary)
	end
	currentMsgs = result.msgs or {}
	renderChat()
	updateBadge()
end

local sending = false
local function sendCurrent()
	if sending or not currentId or not currentSummary or currentSummary.canReply == false then
		return
	end
	local text = input.Text
	if text:match("^%s*$") then
		return
	end
	sending = true
	local convId = currentId
	local ok, message = request("Send", { to = convId, text = text })
	sending = false
	if ok then
		if input.Text == text then
			input.Text = ""
		end
	else
		say(message or "Message not sent.")
	end
end

local function buildChatView(frame: Frame)
	chatView = UI.new("Frame", { Name = "Chat", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 76), Size = UDim2.new(1, 0, 1, -100), Visible = false, Parent = frame })
	local top = UI.new("Frame", { BackgroundColor3 = colors.panel, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -16, 0, 36), Parent = chatView }, { UI.corner(12) })
	local back = UI.button({ Text = "‹", TextSize = 22, BackgroundTransparency = 1, TextColor3 = colors.xp, Size = UDim2.fromOffset(30, 36), Parent = top })
	back.Activated:Connect(function()
		showList()
	end)
	chatTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -110, 1, 0), Parent = top })
	chatAction = UI.button({ Text = "⚙", TextSize = 16, Font = UI.FONT, BackgroundColor3 = colors.panelLight, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(34, 28), Parent = top })
	chatAction.Activated:Connect(function()
		if not currentSummary or not currentId then
			return
		end
		if currentSummary.kind == "group" then
			showSettings(currentId, nil)
		elseif currentSummary.with then
			local S = social()
			if S and type(S.openProfile) == "function" then
				pcall(S.openProfile, currentSummary.with)
			end
		end
	end)
	chatDelete = UI.button({ Text = "🗑", TextSize = 14, Font = UI.FONT, BackgroundColor3 = colors.panelLight, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -42, 0.5, 0), Size = UDim2.fromOffset(34, 28), Parent = top })
	local armedAt = 0
	chatDelete.Activated:Connect(function()
		if not currentId or not convos[currentId] then
			showList()
			return
		end
		if os.clock() - armedAt > 3 then
			armedAt = os.clock()
			say("Tap 🗑 again to delete this chat.")
			return
		end
		local id = currentId
		local ok, message = request("Delete", id)
		if ok then
			convos[id] = nil
			showList()
		else
			say(message or "Couldn't delete.")
		end
	end)

	msgList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 1, -114),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = chatView,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		UI.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 6) }),
	})

	readOnlyNote = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 22), Visible = false, Parent = chatView })

	composer = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 70), Parent = chatView })
	local emojiRow = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 0, 28),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		Parent = composer,
	}, { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	input = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "Message",
		PlaceholderColor3 = colors.subtext,
		ClearTextOnFocus = false,
		TextWrapped = true,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = colors.panelLight,
		Position = UDim2.fromOffset(8, 32),
		Size = UDim2.new(1, -78, 0, 36),
		Parent = composer,
	}, { UI.corner(18), UI.padding(8) })
	limitBox(input, Cfg.MAX_LENGTH)
	for i, emoji in Cfg.EMOJI do
		local b = UI.button({ Text = emoji, TextSize = 16, Font = UI.FONT, BackgroundColor3 = colors.panelLight, Size = UDim2.fromOffset(30, 26), LayoutOrder = i, Parent = emojiRow })
		b.Activated:Connect(function()
			input.Text ..= emoji
		end)
	end
	local send = UI.button({ Text = "SEND", TextSize = 13, BackgroundColor3 = BLUE, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 32), Size = UDim2.fromOffset(62, 36), Parent = composer })
	send.Activated:Connect(sendCurrent)
	input.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			sendCurrent()
		end
	end)
end

---------------------------------------------------------------------------
-- Server events
---------------------------------------------------------------------------
local function viewing(convId: string): boolean
	return view == "chat" and currentId == convId and Phone.isOpen() and Phone.currentPage() == APP_ID
end

local function onMsg(summary: any, msg: any)
	if type(msg) ~= "table" then
		return
	end
	local convId = if type(summary) == "table" then summary.id else nil
	if not convId then
		return
	end
	convos[convId] = summary
	local mine = msg.from == player.UserId
	local isHidden = not mine and hidden(msg.from)
	if viewing(convId) then
		local empty = msgList:FindFirstChild("Empty")
		if empty then
			empty:Destroy()
		end
		table.insert(currentMsgs, msg)
		renderMsg(msg)
		scrollToBottom()
		if not mine then
			task.spawn(function()
				local ok, _, fresh = request("Read", convId)
				if ok and type(fresh) == "table" then
					convos[convId] = fresh
				end
				updateBadge()
			end)
		end
	elseif not mine and not isHidden and not summary.muted then
		if msg.kind == "invite" and msg.invite then
			HUD.push("INVITE FROM " .. string.upper(msg.name), msg.invite.icon .. " " .. msg.invite.title .. " — open Messages to answer.")
		elseif summary.kind == "group" then
			HUD.push(summary.icon .. " " .. summary.title, (if msg.kind == "text" then msg.name .. ": " else "") .. msg.text)
		else
			HUD.push((summary.icon or "💬") .. " " .. msg.name, msg.text)
		end
	end
	if view == "chat" and currentId == convId then
		currentSummary = summary
	end
	queueRender()
end

local function onEvent(kind: string, a: any, b: any, c: any)
	if kind == "State" then
		table.clear(convos)
		for _, s in (if type(a) == "table" then a else {}) do
			convos[s.id] = s
		end
		queueRender()
	elseif kind == "Msg" then
		onMsg(a, b)
	elseif kind == "Summary" and type(a) == "table" then
		convos[a.id] = a
		if view == "chat" and currentId == a.id then
			setChatHeader(a)
		end
		queueRender()
	elseif kind == "InviteState" then
		if currentId == a then
			for _, m in currentMsgs do
				if m.id == b and m.invite then
					m.invite.state = c
				end
			end
			local update = inviteCards[b]
			if update then
				update(c)
			end
		end
	elseif kind == "Removed" then
		convos[a] = nil
		if currentId == a and (view == "chat" or view == "settings" or view == "add") then
			showList()
		end
		queueRender()
	elseif kind == "Gps" and type(a) == "string" and typeof(b) == "Vector3" then
		Phone.setGPS(a, b)
	end
end

---------------------------------------------------------------------------
-- Interaction menu + public helpers
---------------------------------------------------------------------------
-- Opens the phone straight into a chat with this user.
function Messages.openChatWith(userId: number)
	pendingChat = "d" .. userId
	if Phone.isOpen() and Phone.currentPage() == APP_ID then
		openChat(pendingChat :: string)
		return
	end
	Phone.setOpen(true) -- re-runs the app's open function if Messages was the last page
	if Phone.currentPage() ~= APP_ID then
		Phone.showPage(APP_ID) -- its open function picks up pendingChat
	end
end

local function invite(target: Player, kind: string)
	local ok, message = request("Invite", { userId = target.UserId, kind = kind })
	HUD.push(if ok then "INVITE SENT" else "INVITE", message or (if ok then "Sent." else "Couldn't send the invite."))
end

local function registerMenu(S: any)
	if type(S) ~= "table" or type(S.addMenuAction) ~= "function" then
		return
	end
	S.addMenuAction({
		id = "messages_send",
		label = "SEND MESSAGE",
		order = 20,
		run = function(target: Player)
			Messages.openChatWith(target.UserId)
		end,
	})
	S.addMenuAction({
		id = "messages_invite_ball",
		label = "INVITE TO BASKETBALL",
		order = 21,
		run = function(target: Player)
			invite(target, "basketball")
		end,
	})
	S.addMenuAction({
		id = "messages_invite_home",
		label = "INVITE TO MY PLACE",
		order = 22,
		run = function(target: Player)
			invite(target, "apartment")
		end,
	})
end

-- Unread count badge on the home-screen icon (Phone builds the icon after start()).
local function attachIconBadge()
	local playerGui = player:WaitForChild("PlayerGui")
	local phoneGui = playerGui:WaitForChild("CityGrindPhone", 60)
	local apps = phoneGui and phoneGui:WaitForChild("Phone", 10)
	apps = apps and apps:WaitForChild("Screen", 10)
	apps = apps and apps:WaitForChild("Home", 10)
	apps = apps and apps:WaitForChild("Apps", 10)
	local cell = apps and apps:WaitForChild(APP_ID, 10)
	local button = cell and cell:FindFirstChild("Icon")
	if not button then
		return
	end
	iconBadge = UI.new("TextLabel", {
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
		Parent = button,
	}, { UI.corner(10) })
	updateBadge()
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Messages.start()
	Phone.addApp({ id = APP_ID, label = "Messages", icon = "💬", color = Color3.fromRGB(60, 200, 90) }, function(list: ScrollingFrame, frame: Frame)
		content = list
		appFrame = frame
		buildChatView(frame)
		banner = UI.label({
			Text = "",
			TextWrapped = true,
			Font = UI.FONT_BOLD,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundTransparency = 0.05,
			BackgroundColor3 = colors.panel,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -30),
			Size = UDim2.new(1, -24, 0, 34),
			Visible = false,
			ZIndex = 10,
			Parent = appFrame,
		}, { UI.corner(10), UI.stroke(colors.accent, 1, 0.3) })
		return function()
			if pendingChat then
				openChat(pendingChat)
			elseif view == "chat" and currentId then
				openChat(currentId)
			elseif view == "list" then
				showList()
			end
		end
	end)

	-- Interaction menu entries (Social may load before or after us)
	local socialScript = script.Parent:FindFirstChild("Social")
	if socialScript then
		local S = social()
		registerMenu(S)
		if S and typeof(S.changed) == "Instance" and S.changed:IsA("BindableEvent") then
			S.changed.Event:Connect(queueRender)
		end
	else
		task.spawn(function()
			local found = script.Parent:WaitForChild("Social", 30)
			if found then
				local S = social()
				registerMenu(S)
				if S and typeof(S.changed) == "Instance" and S.changed:IsA("BindableEvent") then
					S.changed.Event:Connect(queueRender)
				end
			end
		end)
	end

	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		Request = remotes:WaitForChild("MessagesRequest") :: RemoteFunction
		local Event = remotes:WaitForChild("MessagesEvent") :: RemoteEvent
		Event.OnClientEvent:Connect(onEvent)
		local ok, _, list = request("GetState")
		if ok and type(list) == "table" then
			for _, s in list do
				convos[s.id] = convos[s.id] or s
			end
			queueRender()
		end
	end)
	task.spawn(attachIconBadge)
end

return Messages
