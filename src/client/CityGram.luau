-- CITY GRIND: CityGram app + follows (sections 27, 28, 36).
-- Feeds: Following, Popular (most liked, last 48 h), Nearby (players in this server),
-- Inbox (posts shared with you) and Me. Post cards re-render the photo's scene
-- snapshot, show the (server-filtered) caption, creator (tap -> profile), location,
-- likes, comments, share and views. FOLLOW / UNFOLLOW is added to the player
-- interaction menu, and CityGram.buildProfileSection(...) draws the followers /
-- following / latest posts / FOLLOW block inside Social's profile card.
--
-- Public client API:
--   CityGram.isFollowing(userId) -> boolean        (local cache, kept in sync by the server)
--   CityGram.setFollow(userId, follow) -> (ok, message)
--   CityGram.openUser(userId, name?)               open the phone on someone's posts
--   CityGram.buildProfileSection(parent, userId, layoutOrder)

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local Media = require(script.Parent:WaitForChild("Media"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local MediaConfig = require(shared:WaitForChild("MediaConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local CityGram = {}

local APP_COLOR = Color3.fromRGB(200, 70, 160)
local LIKE_COLOR = Color3.fromRGB(235, 70, 110)
local GOOD = Color3.fromRGB(50, 170, 90)
local BLUE = Color3.fromRGB(40, 120, 220)
local DIM = Color3.fromRGB(60, 60, 72)
local INNER_W = Phone.width - 44 -- card width minus padding

local Action: RemoteFunction? = nil
local Profile: RemoteFunction? = nil

local followingSet: { [number]: boolean? } = {}
local snapCache: { [string]: any } = {}
local inboxCount = 0

local content: ScrollingFrame
local pageFrame: Frame
local tab = "following"
local userTab: { id: number, name: string }? = nil
local token = 0

---------------------------------------------------------------------------
-- Server calls
---------------------------------------------------------------------------
local function act(action: string, a: any?, b: any?): (boolean, string?, any)
	if not Action then
		return false, "Still connecting...", nil
	end
	local ok, success, message, data = pcall(function()
		return (Action :: RemoteFunction):InvokeServer(action, a, b)
	end)
	if not ok then
		return false, "Couldn't reach the server.", nil
	end
	return success == true, message, data
end

local function toast(ok: boolean, message: string?)
	if message then
		HUD.push(if ok then "CITYGRAM" else "CAN'T DO THAT", message)
	end
end

local function openProfile(userId: number)
	local module = script.Parent:FindFirstChild("Social")
	if module then
		local ok, Social = pcall(require, module)
		if ok and Social.openProfile then
			Social.openProfile(userId)
		end
	end
end

local function isFriend(userId: number): boolean
	local module = script.Parent:FindFirstChild("Social")
	if module then
		local ok, Social = pcall(require, module)
		if ok and Social.isFriend then
			return Social.isFriend(userId) == true
		end
	end
	return false
end

local function fetchSnap(postId: string): any
	if snapCache[postId] then
		return snapCache[postId]
	end
	local ok, _, snap = act("snap", postId)
	if ok and type(snap) == "table" then
		snapCache[postId] = snap
		return snap
	end
	return nil
end

---------------------------------------------------------------------------
-- Follows
---------------------------------------------------------------------------
local refresh: () -> ()

function CityGram.isFollowing(userId: number): boolean
	return followingSet[userId] == true
end

function CityGram.setFollow(userId: number, follow: boolean): (boolean, string?)
	local ok, message = act(if follow then "follow" else "unfollow", userId)
	if ok then
		if follow then
			followingSet[userId] = true
		else
			followingSet[userId] = nil
		end
	end
	toast(ok, message)
	return ok, message
end

---------------------------------------------------------------------------
-- Overlay panels inside the app page (comments, share, follow lists)
---------------------------------------------------------------------------
local panel: Frame
local panelTitle: TextLabel
local panelList: ScrollingFrame
local panelInputRow: Frame
local panelInput: TextBox
local panelSend: TextButton
local panelSendFn: ((string) -> ())? = nil

local function closePanel()
	if panel then
		panel.Visible = false
	end
	panelSendFn = nil
end

local function buildPanel(frame: Frame)
	panel = UI.new("Frame", {
		Name = "CityGramPanel",
		BackgroundColor3 = Color3.fromRGB(14, 14, 20),
		Position = UDim2.fromOffset(0, 76),
		Size = UDim2.new(1, 0, 1, -104),
		Visible = false,
		ZIndex = 10,
		Active = true,
		Parent = frame,
	})
	panelTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -60, 0, 30), ZIndex = 11, Parent = panel })
	local close = UI.button({ Text = "✕", TextSize = 14, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.fromOffset(30, 28), ZIndex = 11, Parent = panel })
	close.Activated:Connect(closePanel)
	panelList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 1, -80),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ZIndex = 11,
		Parent = panel,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	})
	panelInputRow = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 10, 1, -6), Size = UDim2.new(1, -20, 0, 36), ZIndex = 11, Parent = panel })
	panelInput = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "Add a comment...",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 13,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, -66, 1, 0),
		ZIndex = 11,
		Parent = panelInputRow,
	}, { UI.corner(10), UI.padding(6) })
	panelSend = UI.button({ Text = "SEND", TextSize = 12, BackgroundColor3 = BLUE, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 60, 1, 0), ZIndex = 12, Parent = panelInputRow })
	panelSend.Activated:Connect(function()
		if panelSendFn then
			panelSendFn(panelInput.Text)
		end
	end)
	panelInput.FocusLost:Connect(function(enter)
		if enter and panelSendFn then
			panelSendFn(panelInput.Text)
		end
	end)
end

local function openPanel(title: string, withInput: boolean)
	panelTitle.Text = title
	Phone.clear(panelList)
	panelInputRow.Visible = withInput
	panelList.Size = if withInput then UDim2.new(1, 0, 1, -80) else UDim2.new(1, 0, 1, -38)
	panelInput.Text = ""
	panel.Visible = true
end

local function panelRow(order: number, height: number): Frame
	return UI.new("Frame", { BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, -20, 0, height), LayoutOrder = order, ZIndex = 11, Parent = panelList }, { UI.corner(10), UI.padding(8) })
end

local function personRow(order: number, userId: number, name: string, sub: string?)
	local row = panelRow(order, if sub then 40 else 30)
	local b = UI.new("TextButton", { Text = "@" .. name, Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.text, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), ZIndex = 12, Parent = row })
	b.Activated:Connect(function()
		openProfile(userId)
	end)
	if sub then
		UI.label({ Text = sub, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 14), ZIndex = 12, Parent = row })
	end
	return row
end

local function showFollowList(userId: number, which: string)
	openPanel(if which == "followers" then "FOLLOWERS" else "FOLLOWING", false)
	local ok, message, data = act(which, userId)
	if not ok or type(data) ~= "table" then
		UI.label({ Text = message or "Couldn't load.", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 20), ZIndex = 11, Parent = panelList })
		return
	end
	panelTitle.Text = string.format("%s (%d)", panelTitle.Text, data.total or #data.list)
	if #data.list == 0 then
		UI.label({ Text = "Nobody yet.", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 24), ZIndex = 11, Parent = panelList })
	end
	for i, e in data.list do
		personRow(i, e.u, tostring(e.n), if e.online then "🟢 In this server" else nil)
	end
end

local function updateCount(label: TextLabel, prefix: string, n: number)
	label.Text = prefix .. " " .. tostring(n)
end

local function showComments(post: any, countLabel: TextLabel?)
	openPanel("COMMENTS", true)
	local function draw(list: { any })
		Phone.clear(panelList)
		if #list == 0 then
			UI.label({ Text = "No comments yet. Say something nice!", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 24), ZIndex = 11, Parent = panelList })
		end
		for i, c in list do
			local text = tostring(c.x)
			local h = TextService:GetTextSize(text, 13, UI.FONT, Vector2.new(INNER_W, 1000)).Y
			local row = panelRow(i, 36 + h)
			local name = UI.new("TextButton", { Text = "@" .. tostring(c.n), Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.xp, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1, Size = UDim2.new(1, -60, 0, 14), ZIndex = 12, Parent = row })
			name.Activated:Connect(function()
				openProfile(c.u)
			end)
			UI.label({ Text = UI.timeAgo(c.t or 0), TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(60, 14), ZIndex = 12, Parent = row })
			UI.label({ Text = text, TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, h + 2), ZIndex = 12, Parent = row })
		end
		panelList.CanvasPosition = Vector2.new(0, 100000)
	end
	local ok, message, data = act("comments", post.id)
	if not ok or type(data) ~= "table" then
		toast(false, message)
		closePanel()
		return
	end
	draw(data.comments)
	local sending = false
	panelSendFn = function(text: string)
		if sending or text:match("^%s*$") then
			return
		end
		if (utf8.len(text) or 0) > MediaConfig.COMMENT_MAX then
			toast(false, string.format("Comments are up to %d characters.", MediaConfig.COMMENT_MAX))
			return
		end
		sending = true
		local okC, msg, result = act("comment", post.id, text)
		sending = false
		if okC and type(result) == "table" then
			panelInput.Text = ""
			draw(result.comments)
			post.comments = result.post.comments
			if countLabel then
				updateCount(countLabel, "💬", post.comments)
			end
		else
			toast(false, msg)
		end
	end
end

local function showShare(post: any)
	openPanel("SHARE WITH...", false)
	local others = {}
	for _, p in Players:GetPlayers() do
		if p ~= player then
			table.insert(others, { p = p, friend = isFriend(p.UserId) })
		end
	end
	table.sort(others, function(a, b)
		if a.friend ~= b.friend then
			return a.friend
		end
		return a.p.DisplayName < b.p.DisplayName
	end)
	if #others == 0 then
		UI.label({ Text = "Nobody else is in this server right now.", TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 40), ZIndex = 11, Parent = panelList })
	end
	for i, e in others do
		local row = panelRow(i, 36)
		UI.label({ Text = (if e.friend then "🤝 " else "") .. e.p.DisplayName, Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(1, -70, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 12, Parent = row })
		local send = UI.button({ Text = "SEND", TextSize = 12, BackgroundColor3 = BLUE, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(60, 26), ZIndex = 12, Parent = row })
		local target = e.p
		send.Activated:Connect(function()
			local ok, message = act("share", post.id, target.UserId)
			toast(ok, message)
			if ok then
				send.Text = "SENT"
				send.BackgroundColor3 = GOOD
				send.AutoButtonColor = false
			end
		end)
	end
end

---------------------------------------------------------------------------
-- Post cards
---------------------------------------------------------------------------
local function openPostViewer(post: any)
	local snap = fetchSnap(post.id)
	if not snap then
		toast(false, "That photo couldn't be loaded.")
		return
	end
	Media.openViewer({
		snap = snap,
		title = "@" .. tostring(post.n) .. (if post.cap ~= "" then ": " .. tostring(post.cap) else ""),
		sub = Media.describe(snap, UI.timeAgo(post.t or 0)),
		actions = {
			{
				label = "👤 PROFILE",
				color = DIM,
				fn = function()
					Media.closeViewer()
					openProfile(post.u)
				end,
			},
		},
	})
end

local function postCard(parent: Instance, post: any, order: number, myToken: number)
	local caption = tostring(post.cap or "")
	local capH = if caption ~= "" then TextService:GetTextSize(caption, 13, UI.FONT, Vector2.new(INNER_W, 1000)).Y + 4 else 0
	local imageH = math.floor(INNER_W * 0.75)
	local extra = if post.sharedBy then 16 else 0
	local card = Phone.card(parent, 40 + extra + imageH + 8 + capH + 40, order)

	local name = UI.new("TextButton", { Text = "@" .. tostring(post.n), Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = colors.text, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1, Size = UDim2.new(1, -70, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	name.Activated:Connect(function()
		openProfile(post.u)
	end)
	UI.label({ Text = UI.timeAgo(post.t or 0), TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(70, 18), Parent = card })
	UI.label({ Text = "📍 " .. (if post.l and post.l ~= "" then tostring(post.l) else "The city"), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	if post.sharedBy then
		UI.label({ Text = "↗ Shared by @" .. tostring(post.sharedBy), Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = colors.xp, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 14), Parent = card })
	end

	local imageY = 38 + extra
	local vp = UI.new("ViewportFrame", { BackgroundColor3 = Color3.fromRGB(30, 30, 40), Position = UDim2.fromOffset(0, imageY), Size = UDim2.new(1, 0, 0, imageH), Parent = card }, { UI.corner(10) })
	local loading = UI.label({ Text = "Developing photo...", TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, imageY), Size = UDim2.new(1, 0, 0, imageH), Parent = card })
	local open = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, imageY), Size = UDim2.new(1, 0, 0, imageH), ZIndex = 3, Parent = card })
	open.Activated:Connect(function()
		openPostViewer(post)
	end)

	local y = imageY + imageH + 6
	if caption ~= "" then
		UI.label({ Text = caption, TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, capH), Parent = card })
		y += capH
	end

	local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, y + 4), Size = UDim2.new(1, 0, 0, 30), Parent = card }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }),
	})
	local likeB = UI.button({ Text = "", TextSize = 12, Size = UDim2.fromOffset(58, 28), LayoutOrder = 1, Parent = row })
	local function paintLike()
		likeB.Text = (if post.liked then "♥ " else "♡ ") .. tostring(post.likes)
		likeB.BackgroundColor3 = if post.liked then LIKE_COLOR else DIM
	end
	paintLike()
	local busy = false
	likeB.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		local ok, message, v = act(if post.liked then "unlike" else "like", post.id)
		busy = false
		if ok and type(v) == "table" then
			post.liked = v.liked
			post.likes = v.likes
			paintLike()
		else
			toast(false, message)
		end
	end)
	local commentB = UI.button({ Text = "💬 " .. tostring(post.comments or 0), TextSize = 12, BackgroundColor3 = DIM, Size = UDim2.fromOffset(52, 28), LayoutOrder = 2, Parent = row })
	commentB.Activated:Connect(function()
		showComments(post, commentB)
	end)
	local shareB = UI.button({ Text = "↗", TextSize = 14, BackgroundColor3 = DIM, Size = UDim2.fromOffset(32, 28), LayoutOrder = 3, Parent = row })
	shareB.Activated:Connect(function()
		showShare(post)
	end)
	UI.label({ Text = "👁 " .. tostring(post.views or 0), TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.fromOffset(44, 28), LayoutOrder = 4, Parent = row })
	if post.mine then
		local armed = false
		local del = UI.button({ Text = "🗑", TextSize = 13, BackgroundColor3 = DIM, Size = UDim2.fromOffset(32, 28), LayoutOrder = 5, Parent = row })
		del.Activated:Connect(function()
			if not armed then
				armed = true
				del.BackgroundColor3 = colors.danger
				HUD.push("CITYGRAM", "Tap 🗑 again to delete this post.")
				task.delay(4, function()
					armed = false
					if del.Parent then
						del.BackgroundColor3 = DIM
					end
				end)
				return
			end
			local ok, message = act("delete", post.id)
			toast(ok, message)
			if ok then
				card:Destroy()
			end
		end)
	end

	-- develop the photo a moment later (keeps scrolling smooth), then count the view
	task.spawn(function()
		task.wait(0.15 + (order % 20) * 0.25)
		if myToken ~= token or not card.Parent then
			return
		end
		local snap = fetchSnap(post.id)
		if myToken ~= token or not card.Parent then
			return
		end
		if snap then
			loading:Destroy()
			Media.render(vp, snap, MediaConfig.FEED_PARTS)
			if not post.mine then
				act("view", post.id)
			end
		else
			loading.Text = "Photo unavailable"
		end
	end)
end

---------------------------------------------------------------------------
-- App page
---------------------------------------------------------------------------
local TABS = {
	{ id = "following", label = "Follow" },
	{ id = "popular", label = "Popular" },
	{ id = "nearby", label = "Nearby" },
	{ id = "inbox", label = "Inbox" },
	{ id = "me", label = "Me" },
}

local function tabBar(order: number)
	local bar = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = order, Parent = content }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, t in TABS do
		local label = t.label
		if t.id == "inbox" and inboxCount > 0 then
			label ..= " " .. inboxCount
		end
		local active = (userTab == nil and tab == t.id)
		local b = UI.button({ Text = label, TextSize = 11, BackgroundColor3 = if active then APP_COLOR else DIM, Size = UDim2.new(0.2, -4, 1, 0), LayoutOrder = i, Parent = bar })
		b.Activated:Connect(function()
			tab = t.id
			userTab = nil
			closePanel()
			refresh()
		end)
	end
end

local function emptyCard(order: number, text: string)
	local c = Phone.card(content, 64, order)
	UI.label({ Text = text, TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = c })
end

local function counts(userId: number?): (number, number, number)
	if userId == nil or userId == player.UserId then
		return player:GetAttribute("Followers") or 0, player:GetAttribute("Following") or 0, player:GetAttribute("CityGramPosts") or 0
	end
	return 0, 0, 0
end

local function meHeader(order: number)
	local c = Phone.card(content, 112, order)
	local followers, following, posts = counts(nil)
	UI.label({ Text = "@" .. player.DisplayName, Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 20), Parent = c })
	UI.label({ Text = string.format("%d followers  ·  %d following  ·  %d posts", followers, following, posts), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 16), Parent = c })
	local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 30), Parent = c }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
	})
	local f1 = UI.button({ Text = "FOLLOWERS", TextSize = 11, BackgroundColor3 = DIM, Size = UDim2.new(0.5, -3, 1, 0), Parent = row })
	f1.Activated:Connect(function()
		showFollowList(player.UserId, "followers")
	end)
	local f2 = UI.button({ Text = "FOLLOWING", TextSize = 11, BackgroundColor3 = DIM, Size = UDim2.new(0.5, -3, 1, 0), Parent = row })
	f2.Activated:Connect(function()
		showFollowList(player.UserId, "following")
	end)
	local newPost = UI.button({ Text = "＋ NEW POST (pick a photo in Gallery)", TextSize = 11, BackgroundColor3 = APP_COLOR, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 28), Parent = c })
	newPost.Activated:Connect(function()
		Phone.showPage("Gallery")
		HUD.push("CITYGRAM", "Tap a photo, write a caption and press POST.")
	end)
end

local function userHeader(order: number, u: { id: number, name: string })
	local c = Phone.card(content, 96, order)
	local back = UI.button({ Text = "‹ Feed", TextSize = 12, BackgroundColor3 = DIM, Size = UDim2.fromOffset(60, 24), Parent = c })
	back.Activated:Connect(function()
		userTab = nil
		refresh()
	end)
	UI.label({ Text = "@" .. u.name, Font = UI.FONT_BLACK, TextSize = 15, Position = UDim2.fromOffset(68, 0), Size = UDim2.new(1, -68, 0, 24), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
	local info = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 16), Parent = c })
	local row = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 28), Parent = c }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
	})
	task.spawn(function()
		local ok, data = pcall(function()
			return if Profile then (Profile :: RemoteFunction):InvokeServer(u.id) else nil
		end)
		if not ok or type(data) ~= "table" or not c.Parent then
			return
		end
		info.Text = string.format("%d followers  ·  %d following  ·  %d posts", data.followers or 0, data.following or 0, data.postCount or 0)
		if not data.self then
			local following = data.isFollowing == true
			local fb = UI.button({ Text = if following then "UNFOLLOW" else "FOLLOW", TextSize = 12, BackgroundColor3 = if following then DIM else APP_COLOR, Size = UDim2.new(0.5, -3, 1, 0), Parent = row })
			fb.Activated:Connect(function()
				if CityGram.setFollow(u.id, not following) then
					refresh()
				end
			end)
		end
		local pb = UI.button({ Text = "PROFILE", TextSize = 12, BackgroundColor3 = DIM, Size = UDim2.new(0.5, -3, 1, 0), Parent = row })
		pb.Activated:Connect(function()
			openProfile(u.id)
		end)
	end)
end

refresh = function()
	if not content then
		return
	end
	token += 1
	local myToken = token
	Phone.clear(content)
	tabBar(0)
	local feedTab, feedUser = tab, nil
	if userTab then
		userHeader(1, userTab)
		feedTab, feedUser = "user", userTab.id
	elseif tab == "me" then
		meHeader(1)
		feedTab, feedUser = "user", player.UserId
	end
	local loading = UI.label({ Text = "Loading...", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 24), LayoutOrder = 2, Parent = content })
	local ok, message, data = act("feed", feedTab, feedUser)
	if myToken ~= token then
		return
	end
	loading:Destroy()
	if not ok or type(data) ~= "table" then
		emptyCard(2, message or "CityGram is unavailable right now.")
		return
	end
	if #data.posts == 0 then
		local text = ({
			following = "Follow players to see their posts here. Walk up to someone and choose FOLLOW.",
			popular = "No liked posts in the last 48 hours yet. Be the first!",
			nearby = "Nobody in this server has posted yet.",
			inbox = "Posts people share with you show up here.",
			user = if feedUser == player.UserId then "You haven't posted yet. Take a photo with the Camera app!" else "No posts yet.",
		})[feedTab] or "Nothing here yet."
		emptyCard(2, text)
		return
	end
	for i, post in data.posts do
		postCard(content, post, 1 + i, myToken)
	end
	if tab == "inbox" and not userTab then
		inboxCount = 0
	end
end

function CityGram.openUser(userId: number, name: string?)
	if type(userId) ~= "number" then
		return
	end
	local p = Players:GetPlayerByUserId(userId)
	userTab = { id = userId, name = name or (if p then p.DisplayName else "Player") }
	Phone.setOpen(true)
	if Phone.currentPage() == "CityGram" then
		refresh()
	else
		Phone.showPage("CityGram")
	end
end

---------------------------------------------------------------------------
-- Profile card section (called from Social's profile card)
---------------------------------------------------------------------------
function CityGram.buildProfileSection(parent: Instance, userId: number, layoutOrder: number)
	local c = Phone.card(parent, 150, layoutOrder)
	UI.label({ Text = "CITYGRAM", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = c })
	local stats = UI.label({ Text = "Loading...", Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 18), Parent = c })
	local thumbs = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 0, 52), Parent = c }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local buttons = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 30), Parent = c }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
	})
	task.spawn(function()
		local ok, data = pcall(function()
			return if Profile then (Profile :: RemoteFunction):InvokeServer(userId) else nil
		end)
		if not c.Parent then
			return
		end
		if not ok or type(data) ~= "table" then
			stats.Text = "CityGram unavailable right now."
			return
		end
		stats.Text = string.format("%d FOLLOWERS  ·  %d FOLLOWING  ·  %d POSTS", data.followers or 0, data.following or 0, data.postCount or 0)
		local function thumb(order: number, label: string?, loader: () -> any, onOpen: (any) -> ())
			local cell = UI.new("TextButton", { Text = "", BackgroundColor3 = Color3.fromRGB(30, 30, 40), Size = UDim2.fromOffset(62, 52), LayoutOrder = order, Parent = thumbs }, { UI.corner(8) })
			local vp = UI.new("ViewportFrame", { BackgroundColor3 = Color3.fromRGB(30, 30, 40), Size = UDim2.fromScale(1, 1), Parent = cell }, { UI.corner(8) })
			if label then
				UI.label({ Text = label, TextSize = 11, Position = UDim2.fromOffset(3, 1), Size = UDim2.fromOffset(20, 14), ZIndex = 3, Parent = cell })
			end
			local snap: any = nil
			cell.Activated:Connect(function()
				if snap then
					onOpen(snap)
				end
			end)
			task.spawn(function()
				snap = loader()
				if snap and vp.Parent then
					Media.render(vp, snap, MediaConfig.THUMB_PARTS)
				end
			end)
		end
		if type(data.profilePhoto) == "string" then
			local id = data.profilePhoto
			thumb(0, "👤", function()
				return Media.fetchPhoto(id)
			end, function(snap)
				Media.openViewer({ snap = snap, title = "Profile picture", sub = Media.describe(snap) })
			end)
		end
		for i, postId in data.posts or {} do
			if type(postId) == "string" then
				thumb(i, nil, function()
					return fetchSnap(postId)
				end, function(snap)
					local okP, _, post = act("post_get", postId)
					Media.openViewer({
						snap = snap,
						title = if okP and type(post) == "table" and post.cap ~= "" then tostring(post.cap) else "Post",
						sub = Media.describe(snap),
					})
				end)
			end
		end
		if #(data.posts or {}) == 0 and type(data.profilePhoto) ~= "string" then
			UI.label({ Text = "No posts yet.", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 1, 0), Parent = thumbs })
		end
		if not data.self then
			local following = data.isFollowing == true
			local fb = UI.button({ Text = if following then "UNFOLLOW" else "FOLLOW", TextSize = 12, BackgroundColor3 = if following then DIM else APP_COLOR, Size = UDim2.new(0.5, -3, 1, 0), Parent = buttons })
			fb.Activated:Connect(function()
				if CityGram.setFollow(userId, not following) then
					following = not following
					fb.Text = if following then "UNFOLLOW" else "FOLLOW"
					fb.BackgroundColor3 = if following then DIM else APP_COLOR
				end
			end)
		end
		local vb = UI.button({ Text = "VIEW POSTS", TextSize = 12, BackgroundColor3 = BLUE, Size = UDim2.new(if data.self then 1 else 0.5, -3, 1, 0), Parent = buttons })
		vb.Activated:Connect(function()
			local profileFrame = c:FindFirstAncestor("Profile")
			if profileFrame and profileFrame:IsA("GuiObject") then
				profileFrame.Visible = false
			end
			local p = Players:GetPlayerByUserId(userId)
			CityGram.openUser(userId, if p then p.DisplayName else nil)
		end)
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function addMenuActions()
	local module = script.Parent:WaitForChild("Social", 30)
	if not module then
		return
	end
	local ok, Social = pcall(require, module)
	if not ok or not Social.addMenuAction then
		return
	end
	Social.addMenuAction({
		id = "citygram_follow",
		label = "📸 FOLLOW",
		order = 32,
		visible = function(target: Player)
			return not followingSet[target.UserId]
		end,
		run = function(target: Player)
			CityGram.setFollow(target.UserId, true)
		end,
	})
	Social.addMenuAction({
		id = "citygram_unfollow",
		label = "📸 UNFOLLOW",
		order = 32,
		visible = function(target: Player)
			return followingSet[target.UserId] == true
		end,
		run = function(target: Player)
			CityGram.setFollow(target.UserId, false)
		end,
	})
	Social.addMenuAction({
		id = "citygram_posts",
		label = "📸 VIEW POSTS",
		order = 33,
		run = function(target: Player)
			CityGram.openUser(target.UserId, target.DisplayName)
		end,
	})
end

function CityGram.start()
	Phone.addApp({ id = "CityGram", label = "CityGram", icon = "📸", color = APP_COLOR }, function(c, frame)
		content = c
		pageFrame = frame
		buildPanel(pageFrame)
		return function()
			closePanel()
			refresh()
		end
	end)

	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		Action = remotes:WaitForChild("CityGramAction") :: RemoteFunction
		Profile = remotes:WaitForChild("CityGramProfile") :: RemoteFunction
		local Event = remotes:WaitForChild("CityGramEvent") :: RemoteEvent
		Event.OnClientEvent:Connect(function(kind: any, a: any)
			if kind == "Following" and type(a) == "table" then
				table.clear(followingSet)
				for _, id in a do
					if type(id) == "number" then
						followingSet[id] = true
					end
				end
			elseif kind == "Inbox" and type(a) == "number" then
				inboxCount = a
			end
		end)
		local ok, _, ids = act("myFollowing")
		if ok and type(ids) == "table" then
			for _, id in ids do
				if type(id) == "number" then
					followingSet[id] = true
				end
			end
		end
	end)
	task.spawn(addMenuActions)

	-- gamepad: B closes an open comments / share panel
	ContextActionService:BindActionAtPriority("CityGramPanelClose", function(_, state)
		if state == Enum.UserInputState.Begin and panel and panel.Visible and Phone.isOpen() then
			closePanel()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, 2500, Enum.KeyCode.ButtonB)
end

return CityGram
