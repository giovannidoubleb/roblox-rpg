-- CITY GRIND: social client (spec 21, 28, 29, 44-47, 96, 97, 101).
-- * Player interaction menu: a "•••" prompt over anyone within 10 studs (key T,
--   gamepad DPad-Down, tap on touch) opens VIEW PROFILE / friend / emotes / other
--   modules' actions (Social.addMenuAction) / MUTE / BLOCK / REPORT.
-- * Profile cards (Social.openProfile(userId)).
-- * "Friends" phone app: friends + status, requests, nearby players, your status and
--   profile customization, privacy settings with block / mute lists.
-- * Hides the nametag and prompt of anyone you blocked or who blocked you.
-- The server decides everything; this file only asks and draws.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local SC = require(shared:WaitForChild("SocialConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Social = {}

-- Fired whenever friends / requests / block / mute lists change.
Social.changed = Instance.new("BindableEvent")

type MenuAction = {
	id: string,
	label: string,
	order: number,
	visible: ((target: Player) -> boolean)?,
	run: (target: Player) -> (),
}
local menuActions: { MenuAction } = {}

local remotes: Instance? = nil
local SocialAction: RemoteFunction? = nil
local SocialProfile: RemoteFunction? = nil
local SocialEmote: RemoteEvent? = nil

local state: any = nil
local blockedSet: { [number]: boolean } = {}
local hiddenSet: { [number]: boolean } = {}
local mutedSet: { [number]: boolean } = {}
local friendSet: { [number]: boolean } = {}

local gui: ScreenGui
local GOOD = Color3.fromRGB(50, 170, 90)
local BLUE = Color3.fromRGB(40, 120, 220)
local DIM = Color3.fromRGB(60, 60, 72)

---------------------------------------------------------------------------
-- Server calls
---------------------------------------------------------------------------
local function act(action: string, a: any?, b: any?): (boolean, string?, any)
	if not SocialAction then
		return false, "Still connecting...", nil
	end
	local ok, success, message, extra = pcall(function()
		return (SocialAction :: RemoteFunction):InvokeServer(action, a, b)
	end)
	if not ok then
		return false, "Couldn't reach the server.", nil
	end
	return success == true, message, extra
end

-- Runs an action and shows the server's answer as a toast.
local function actToast(title: string, action: string, a: any?, b: any?): boolean
	local ok, message = act(action, a, b)
	if message then
		HUD.push(if ok then title else "CAN'T DO THAT", message)
	elseif not ok then
		HUD.push("CAN'T DO THAT", "Try again in a moment.")
	end
	return ok
end

local function applyState(newState: any)
	if type(newState) ~= "table" then
		return
	end
	state = newState
	table.clear(blockedSet)
	table.clear(mutedSet)
	table.clear(friendSet)
	table.clear(hiddenSet)
	for _, b in state.blocked or {} do
		blockedSet[b.userId] = true
	end
	for _, m in state.muted or {} do
		mutedSet[m.userId] = true
	end
	for _, f in state.friends or {} do
		friendSet[f.userId] = true
	end
	for _, id in state.hiddenIds or {} do
		hiddenSet[id] = true
	end
	Social.changed:Fire()
end

local function fetchState()
	local ok, _, s = act("state")
	if ok then
		applyState(s)
	end
end

---------------------------------------------------------------------------
-- Public client API
---------------------------------------------------------------------------
-- True if you blocked this user or they blocked you.
function Social.isBlocked(userId: number): boolean
	return blockedSet[userId] == true or hiddenSet[userId] == true
end

function Social.isMuted(userId: number): boolean
	return mutedSet[userId] == true or blockedSet[userId] == true
end

function Social.isFriend(userId: number): boolean
	return friendSet[userId] == true
end

-- Other modules add buttons to the player interaction menu. Works before or after start().
function Social.addMenuAction(action: MenuAction)
	assert(type(action) == "table" and type(action.id) == "string" and type(action.run) == "function", "bad menu action")
	for i, existing in menuActions do
		if existing.id == action.id then
			table.remove(menuActions, i)
			break
		end
	end
	table.insert(menuActions, {
		id = action.id,
		label = tostring(action.label or action.id),
		order = tonumber(action.order) or 50,
		visible = action.visible,
		run = action.run,
	})
	table.sort(menuActions, function(a, b)
		return a.order < b.order
	end)
end

---------------------------------------------------------------------------
-- Small UI helpers
---------------------------------------------------------------------------
local function modal(name: string, width: number, height: number): Frame
	local frame = UI.new("Frame", {
		Name = name,
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.03,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		Visible = false,
		Parent = gui,
	}, { UI.corner(16), UI.stroke(Color3.fromRGB(70, 70, 85), 1.5) })
	UI.new("UISizeConstraint", { MaxSize = Vector2.new(width, height), Parent = frame })
	return frame
end

local function selectFirst(container: Instance)
	if UserInputService.GamepadEnabled then
		for _, d in container:GetDescendants() do
			if d:IsA("GuiButton") and d.Visible then
				GuiService.SelectedObject = d
				return
			end
		end
	end
end

local function statusText(status: string?): string
	if not status or status == "" then
		return ""
	end
	local icon = SC.STATUS_ICONS[status]
	return if icon and icon ~= "" then icon .. " " .. status else status
end

local function statusColor(status: string): Color3
	if status == "Not in this server" then
		return colors.subtext
	elseif status == "Do Not Disturb" or status == "Busy" then
		return colors.danger
	end
	return colors.cash
end

local function myRoot(): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function distanceTo(other: Player): number
	local mine = myRoot()
	local c = other.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	if not mine or not r or not r:IsA("BasePart") then
		return math.huge
	end
	return (mine.Position - r.Position).Magnitude
end

---------------------------------------------------------------------------
-- Report panel (spec 101): Roblox's own report flow
---------------------------------------------------------------------------
local reportFrame: Frame
local reportBody: TextLabel
local reportBlock: TextButton
local reportTarget: Player? = nil
local blockPlayer: (Player) -> ()

local function buildReport()
	reportFrame = modal("Report", 300, 236)
	UI.padding(14).Parent = reportFrame
	UI.label({ Text = "REPORT A PLAYER", Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = colors.danger, Size = UDim2.new(1, 0, 0, 20), Parent = reportFrame })
	reportBody = UI.label({
		Text = "",
		TextSize = 14,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 120),
		Parent = reportFrame,
	})
	reportBlock = UI.button({ Text = "BLOCK THEM TOO", TextSize = 14, BackgroundColor3 = colors.danger, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(0.5, -4, 0, 38), Parent = reportFrame })
	local done = UI.button({ Text = "GOT IT", TextSize = 14, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), Size = UDim2.new(0.5, -4, 0, 38), Parent = reportFrame })
	done.Activated:Connect(function()
		reportFrame.Visible = false
	end)
	reportBlock.Activated:Connect(function()
		local target = reportTarget
		reportFrame.Visible = false
		if target and target.Parent then
			blockPlayer(target)
		end
	end)
end

local function openReport(target: Player)
	reportTarget = target
	local menuKey = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "the ☰ Roblox button (top-left)" else "the Roblox menu (Esc)"
	reportBody.Text = string.format(
		"Reports go straight to Roblox's moderators.\n\nOpen %s → Report, then choose %s (@%s) and what happened.",
		menuKey,
		target.DisplayName,
		target.Name
	)
	reportBlock.Visible = not blockedSet[target.UserId]
	reportFrame.Visible = true
	selectFirst(reportFrame)
end

---------------------------------------------------------------------------
-- Block / mute helpers (also offer Roblox's own block prompt)
---------------------------------------------------------------------------
blockPlayer = function(target: Player)
	if actToast("BLOCKED", "block", target.UserId) then
		fetchState()
		pcall(function()
			StarterGui:SetCore("PromptBlockPlayer", target)
		end)
	end
end

local function unblockUser(userId: number)
	if actToast("UNBLOCKED", "unblock", userId) then
		fetchState()
		local target = Players:GetPlayerByUserId(userId)
		if target then
			pcall(function()
				StarterGui:SetCore("PromptUnblockPlayer", target)
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Profile card (spec 28, 29)
---------------------------------------------------------------------------
local profileFrame: Frame
local profileBody: ScrollingFrame
local profileBanner: Frame
local profileAvatar: ImageLabel
local profileName: TextLabel
local profileSub: TextLabel
local profileButtons: Frame
local profileToken = 0
local openFriendsTab: (string) -> ()

local function buildProfileCard()
	profileFrame = modal("Profile", 330, 540)
	profileBanner = UI.new("Frame", { BackgroundColor3 = SC.BANNERS[1], Size = UDim2.new(1, 0, 0, 96), Parent = profileFrame }, { UI.corner(16) })
	-- square off the banner's bottom corners
	UI.new("Frame", { BackgroundColor3 = SC.BANNERS[1], Name = "Fill", Position = UDim2.new(0, 0, 1, -16), Size = UDim2.new(1, 0, 0, 16), Parent = profileBanner })
	profileAvatar = UI.new("ImageLabel", { BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(14, 14), Size = UDim2.fromOffset(68, 68), ZIndex = 2, Parent = profileFrame }, { UI.corner(34), UI.stroke(Color3.new(1, 1, 1), 2) })
	profileName = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 20, TextStrokeTransparency = 0.6, Position = UDim2.fromOffset(92, 18), Size = UDim2.new(1, -140, 0, 24), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 2, Parent = profileFrame })
	profileSub = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextStrokeTransparency = 0.7, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(92, 44), Size = UDim2.new(1, -104, 0, 40), ZIndex = 2, Parent = profileFrame })
	local close = UI.button({ Text = "✕", TextSize = 16, BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.5, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(32, 32), ZIndex = 3, Parent = profileFrame })
	close.Activated:Connect(function()
		profileFrame.Visible = false
	end)
	profileBody = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 104),
		Size = UDim2.new(1, 0, 1, -158),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		Parent = profileFrame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		UI.new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 8) }),
	})
	profileButtons = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -10), Size = UDim2.new(1, -24, 0, 40), Parent = profileFrame }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

local function statRow(parent: Instance, order: number, entries: { { string } }, title: string?)
	local height = if title then 80 else 62
	local row = Phone.card(parent, height, order)
	local y = 0
	if title then
		UI.label({ Text = title, Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = row })
		y = 16
	end
	for i, entry in entries do
		local x = (i - 1) / #entries
		UI.label({ Text = entry[2], Font = UI.FONT_BLACK, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(x, 0, 0, y), Size = UDim2.new(1 / #entries, 0, 0, 20), Parent = row })
		UI.label({ Text = entry[1], TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new(x, 0, 0, y + 22), Size = UDim2.new(1 / #entries, 0, 0, 14), Parent = row })
	end
end

local function infoLine(parent: Instance, order: number, label: string, value: string, color: Color3?)
	local row = Phone.card(parent, 40, order)
	UI.label({ Text = label, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(0.42, 0, 1, 0), Parent = row })
	UI.label({ Text = value, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = color or colors.text, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromScale(0.42, 0), Size = UDim2.new(0.58, 0, 1, 0), Parent = row })
end

local function profileButton(text: string, color: Color3, fn: () -> ())
	local b = UI.button({ Text = text, TextSize = 13, BackgroundColor3 = color, Size = UDim2.fromOffset(96, 38), Parent = profileButtons })
	b.Activated:Connect(fn)
	return b
end

local function setBanner(color: Color3)
	profileBanner.BackgroundColor3 = color
	local fill = profileBanner:FindFirstChild("Fill")
	if fill and fill:IsA("Frame") then
		fill.BackgroundColor3 = color
	end
end

function Social.openProfile(userId: number)
	if type(userId) ~= "number" or not profileFrame then
		return
	end
	profileToken += 1
	local token = profileToken
	Phone.clear(profileBody)
	Phone.clear(profileButtons)
	setBanner(SC.BANNERS[8])
	profileName.Text = "Loading..."
	profileSub.Text = ""
	profileAvatar.Image = ""
	profileFrame.Visible = true
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and token == profileToken then
			profileAvatar.Image = image
		end
	end)
	local ok, p = pcall(function()
		return if SocialProfile then (SocialProfile :: RemoteFunction):InvokeServer(userId) else nil
	end)
	if token ~= profileToken then
		return
	end
	if not ok or type(p) ~= "table" then
		profileName.Text = "Profile unavailable"
		profileSub.Text = "Try again in a moment."
		profileButton("CLOSE", DIM, function()
			profileFrame.Visible = false
		end)
		return
	end

	setBanner(SC.BANNERS[p.banner or 0] or SC.BANNERS[1])
	profileName.Text = tostring(p.name)
	local sub = "@" .. tostring(p.username or "")
	if p.level then
		sub ..= "  ·  LV " .. p.level
	end
	if p.title and p.title ~= "" then
		sub ..= "\n" .. tostring(p.title)
	end
	profileSub.Text = sub

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	local badges = {}
	if p.relation == "friends" then
		table.insert(badges, "🤝 Friend")
	end
	if p.robloxFriend then
		table.insert(badges, "⭐ Roblox friend")
	end
	if p.status and p.status ~= "" then
		table.insert(badges, statusText(p.status))
	end
	if #badges > 0 then
		UI.label({ Text = table.concat(badges, "   "), Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.cash, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 18), LayoutOrder = nextOrder(), Parent = profileBody })
	end

	if p.note then
		local c = Phone.card(profileBody, 50, nextOrder())
		UI.label({ Text = tostring(p.note), TextSize = 14, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = c })
	end

	if not p.limited and p.online then
		local rankColor = SC.RANK_COLORS[p.rank] or colors.text
		statRow(profileBody, nextOrder(), {
			{ "Rank", tostring(p.rank) },
			{ "Reputation", tostring(p.reputation) },
			{ "Fame", tostring(p.fame) },
			{ "Friends", tostring(p.friendCount or 0) },
		})
		if p.featured then
			local f = Phone.card(profileBody, 66, nextOrder())
			f.BackgroundColor3 = (SC.BANNERS[p.banner or 0] or SC.BANNERS[1]):Lerp(colors.panelLight, 0.6)
			UI.label({ Text = "FEATURED · " .. string.upper(tostring(p.featured.label)), Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = f })
			UI.label({ Text = tostring(p.featured.value), Font = UI.FONT_BLACK, TextSize = 22, Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 24), Parent = f })
		end
		local bb = p.basketball or {}
		statRow(profileBody, nextOrder(), {
			{ "W - L", string.format("%d-%d", bb.wins or 0, bb.losses or 0) },
			{ "Points", tostring(bb.points or 0) },
			{ "3PT", tostring(bb.threes or 0) },
			{ "Dunks", tostring(bb.dunks or 0) },
		}, "BASKETBALL")
		infoLine(profileBody, nextOrder(), "Reputation rank", tostring(p.rank), rankColor)
		if p.crew then
			local crewColor = if typeof(p.crew.color) == "Color3" then p.crew.color else colors.text
			infoLine(profileBody, nextOrder(), "Crew", string.format("[%s] %s", tostring(p.crew.tag), tostring(p.crew.name)), crewColor)
		else
			infoLine(profileBody, nextOrder(), "Crew", "No crew")
		end
		infoLine(profileBody, nextOrder(), "Home", tostring(p.homeTier))
		infoLine(profileBody, nextOrder(), "Favourite activity", if p.favorite == "None" then "—" else tostring(p.favorite))
		if p.bio and p.bio ~= "" then
			local bioCard = Phone.card(profileBody, 70, nextOrder())
			bioCard.AutomaticSize = Enum.AutomaticSize.Y
			UI.label({ Text = "BIO", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = bioCard })
			UI.label({ Text = tostring(p.bio), TextSize = 14, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 18), Parent = bioCard })
		end
	end

	-- Followers / following / latest posts come from CityGram (Phase 5).
	local CGModule = script.Parent:FindFirstChild("CityGram")
	if CGModule and not p.blocked then
		local okCG, CG = pcall(require, CGModule)
		if okCG and CG.buildProfileSection then
			CG.buildProfileSection(profileBody, userId, nextOrder())
		end
	end

	-- Buttons (all real)
	if p.self then
		profileButton("EDIT", BLUE, function()
			profileFrame.Visible = false
			openFriendsTab("Me")
		end)
	elseif not p.blocked then
		if p.relation == "none" then
			profileButton("ADD FRIEND", GOOD, function()
				if actToast("FRIENDS", "request", userId) then
					Social.openProfile(userId)
				end
			end)
		elseif p.relation == "incoming" then
			profileButton("ACCEPT", GOOD, function()
				if actToast("FRIENDS", "accept", userId) then
					Social.openProfile(userId)
				end
			end)
		elseif p.relation == "outgoing" then
			profileButton("CANCEL REQ", DIM, function()
				if actToast("FRIENDS", "cancel", userId) then
					Social.openProfile(userId)
				end
			end)
		end
	else
		profileButton("UNBLOCK", DIM, function()
			unblockUser(userId)
			Social.openProfile(userId)
		end)
	end
	profileButton("CLOSE", DIM, function()
		profileFrame.Visible = false
	end)
	selectFirst(profileButtons)
end

---------------------------------------------------------------------------
-- Two-person emote request card
---------------------------------------------------------------------------
local emoteCard: Frame
local emoteText: TextLabel
local emoteFrom = 0
local emoteToken = 0

local function respondEmote(accept: boolean)
	emoteCard.Visible = false
	if emoteFrom ~= 0 and SocialEmote then
		SocialEmote:FireServer("respond", emoteFrom, accept)
	end
	emoteFrom = 0
	ContextActionService:UnbindAction("SocialEmoteAccept")
end

local function buildEmoteCard()
	emoteCard = UI.new("Frame", {
		Name = "EmoteRequest",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.05,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 140),
		Size = UDim2.fromOffset(300, 96),
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.stroke(colors.accent, 1.5, 0.2), UI.padding(10) })
	emoteText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 15, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 36), Parent = emoteCard })
	local yes = UI.button({ Text = "ACCEPT", TextSize = 14, BackgroundColor3 = GOOD, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(0.5, -4, 0, 34), Parent = emoteCard })
	local no = UI.button({ Text = "DECLINE", TextSize = 14, BackgroundColor3 = DIM, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), Size = UDim2.new(0.5, -4, 0, 34), Parent = emoteCard })
	yes.Activated:Connect(function()
		respondEmote(true)
	end)
	no.Activated:Connect(function()
		respondEmote(false)
	end)
end

local function showEmoteRequest(fromUserId: number, kind: string, fromName: string)
	if Social.isBlocked(fromUserId) then
		if SocialEmote then
			SocialEmote:FireServer("respond", fromUserId, false)
		end
		return
	end
	local emote = SC.EMOTES[kind]
	if not emote then
		return
	end
	emoteFrom = fromUserId
	emoteToken += 1
	local token = emoteToken
	emoteText.Text = string.format("%s wants a %s!", fromName, emote.label)
	emoteCard.Visible = true
	-- Y (keyboard) / ButtonY (gamepad) accepts without the mouse
	ContextActionService:BindAction("SocialEmoteAccept", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			respondEmote(true)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Y, Enum.KeyCode.ButtonY)
	task.delay(SC.EMOTE_REQUEST_SECONDS, function()
		if token == emoteToken and emoteCard.Visible then
			emoteCard.Visible = false
			emoteFrom = 0
			ContextActionService:UnbindAction("SocialEmoteAccept")
		end
	end)
end

local function doEmote(target: Player?, kind: string)
	if kind == "Wave" then
		local EmotesModule = script.Parent:FindFirstChild("Emotes")
		if EmotesModule then
			local ok = pcall(function()
				require(EmotesModule).play("Wave")
			end)
			if ok then
				return
			end
		end
		if SocialEmote then
			SocialEmote:FireServer("solo", "Wave")
		end
	elseif target and SocialEmote then
		SocialEmote:FireServer("request", target.UserId, kind)
	end
end

---------------------------------------------------------------------------
-- Player interaction menu (spec 21, 96)
---------------------------------------------------------------------------
local menuFrame: Frame
local menuTitle: TextLabel
local menuSub: TextLabel
local menuList: ScrollingFrame
local menuTarget: Player? = nil
local menuToken = 0

local function closeMenu()
	menuTarget = nil
	menuToken += 1
	if menuFrame then
		menuFrame.Visible = false
	end
	ContextActionService:UnbindAction("SocialMenuClose")
end

local function buildMenu()
	menuFrame = UI.new("Frame", {
		Name = "InteractMenu",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, -170, 0.5, 0),
		Size = UDim2.fromOffset(250, 420),
		Visible = false,
		Parent = gui,
	}, { UI.corner(16), UI.stroke(Color3.fromRGB(70, 70, 85), 1.5), UI.padding(12) })
	menuTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 18, Size = UDim2.new(1, -36, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd, Parent = menuFrame })
	menuSub = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 30), Parent = menuFrame })
	local close = UI.button({ Text = "✕", TextSize = 15, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(30, 30), Parent = menuFrame })
	close.Activated:Connect(closeMenu)
	menuList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 1, -56),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		Parent = menuFrame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

local function menuButton(order: number, text: string, color: Color3?, fn: () -> ()): TextButton
	local b = UI.button({ Text = text, TextSize = 14, BackgroundColor3 = color or colors.panelLight, Size = UDim2.new(1, -6, 0, 36), LayoutOrder = order, Parent = menuList })
	b.Activated:Connect(fn)
	return b
end

function Social.openMenu(target: Player)
	if not menuFrame or not target or target == player or not target.Parent then
		return
	end
	menuToken += 1
	local token = menuToken
	menuTarget = target
	Phone.clear(menuList)
	menuTitle.Text = target.DisplayName
	menuSub.Text = "@" .. target.Name .. "  ·  loading..."
	menuFrame.Visible = true
	ContextActionService:BindAction("SocialMenuClose", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			closeMenu()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.ButtonB)

	local ok, _, info = act("query", target.UserId)
	if token ~= menuToken then
		return
	end
	if not ok or type(info) ~= "table" then
		menuSub.Text = "They left the area."
		return
	end
	local subParts = { "@" .. target.Name, "LV " .. tostring(info.level) }
	if info.robloxFriend then
		table.insert(subParts, "⭐ Roblox friend")
	end
	if info.relation == "friends" then
		table.insert(subParts, "🤝 Friend")
	end
	if info.status and info.status ~= "" then
		table.insert(subParts, statusText(info.status))
	end
	menuSub.Text = table.concat(subParts, "  ·  ")

	local userId = target.UserId
	local function reopen()
		if menuTarget == target then
			Social.openMenu(target)
		end
	end

	menuButton(10, "VIEW PROFILE", BLUE, function()
		closeMenu()
		Social.openProfile(userId)
	end)

	if not info.blocked then
		if info.relation == "friends" then
			local armed = false
			local removeBtn: TextButton
			removeBtn = menuButton(20, "REMOVE FRIEND", DIM, function()
				if not armed then
					armed = true
					removeBtn.Text = "TAP AGAIN TO REMOVE"
					removeBtn.BackgroundColor3 = colors.danger
					return
				end
				actToast("FRIENDS", "remove", userId)
				reopen()
			end)
		elseif info.relation == "incoming" then
			menuButton(20, "ACCEPT FRIEND REQUEST", GOOD, function()
				actToast("FRIENDS", "accept", userId)
				reopen()
			end)
		elseif info.relation == "outgoing" then
			menuButton(20, "CANCEL FRIEND REQUEST", DIM, function()
				actToast("FRIENDS", "cancel", userId)
				reopen()
			end)
		elseif info.canInteract then
			menuButton(20, "ADD FRIEND", GOOD, function()
				actToast("FRIENDS", "request", userId)
				reopen()
			end)
		end
	end

	if info.canInteract then
		local near = distanceTo(target) <= SC.EMOTE_RANGE
		menuButton(30, "👋 WAVE", nil, function()
			closeMenu()
			doEmote(target, "Wave")
		end)
		if near then
			for i, kind in { "HighFive", "FistBump", "Handshake" } do
				menuButton(30 + i, (if kind == "HighFive" then "✋ " elseif kind == "FistBump" then "👊 " else "🤝 ") .. SC.EMOTES[kind].label, nil, function()
					closeMenu()
					doEmote(target, kind)
				end)
			end
		end
		-- actions added by other systems (messages, invites...)
		for _, action in menuActions do
			local visible = true
			if action.visible then
				local okVisible, result = pcall(action.visible, target)
				visible = okVisible and result ~= false
			end
			if visible then
				menuButton(100 + action.order, action.label, nil, function()
					closeMenu()
					local okRun, err = pcall(action.run, target)
					if not okRun then
						warn("[CityGrind] menu action " .. action.id .. " failed:", err)
					end
				end)
			end
		end
	elseif info.reason and not info.blocked then
		UI.label({ Text = tostring(info.reason), TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -6, 0, 30), LayoutOrder = 25, Parent = menuList })
	end

	menuButton(900, if info.muted then "🔊 UNMUTE" else "🔇 MUTE", DIM, function()
		actToast("MUTE", if info.muted then "unmute" else "mute", userId)
		fetchState()
		reopen()
	end)
	menuButton(901, if info.blocked then "UNBLOCK" else "⛔ BLOCK", colors.danger, function()
		if info.blocked then
			unblockUser(userId)
		else
			blockPlayer(target)
		end
		reopen()
	end)
	menuButton(902, "🚩 REPORT", DIM, function()
		closeMenu()
		openReport(target)
	end)
	selectFirst(menuList)
end

---------------------------------------------------------------------------
-- "•••" prompts over nearby players + hiding blocked players
---------------------------------------------------------------------------
local prompts: { [Player]: ProximityPrompt } = {}

local function attachPrompt(other: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root or not other.Parent then
		return
	end
	local old = prompts[other]
	if old then
		old:Destroy()
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CityGrindSocialPrompt"
	prompt.ActionText = "•••"
	prompt.ObjectText = other.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.T
	prompt.GamepadKeyCode = Enum.KeyCode.DPadDown
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = SC.INTERACT_RANGE
	prompt.RequiresLineOfSight = false
	prompt.UIOffset = Vector2.new(0, 40)
	prompt.Enabled = not Social.isBlocked(other.UserId)
	prompt.Triggered:Connect(function()
		Social.openMenu(other)
	end)
	prompt.Parent = root
	prompts[other] = prompt
end

local function watchPlayer(other: Player)
	if other == player then
		return
	end
	other.CharacterAdded:Connect(function(character)
		task.spawn(attachPrompt, other, character)
	end)
	if other.Character then
		task.spawn(attachPrompt, other, other.Character)
	end
end

-- Blocked players: no prompt, no nametag. Busy (driving / in a game): no prompts.
local function refreshVisibility()
	local busy = (player:GetAttribute("Driving") or "") ~= "" or player:GetAttribute("InGame") ~= nil
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local hidden = Social.isBlocked(other.UserId)
			local prompt = prompts[other]
			if prompt and prompt.Parent then
				prompt.Enabled = not hidden and not busy
			end
			local head = other.Character and other.Character:FindFirstChild("Head")
			local tag = head and head:FindFirstChild("CityGrindTag")
			if tag and tag:IsA("BillboardGui") then
				tag.Enabled = not hidden
			end
		end
	end
	if menuTarget and Social.isBlocked(menuTarget.UserId) then
		-- keep the menu open so UNBLOCK stays reachable for our own blocks
		if hiddenSet[menuTarget.UserId] then
			closeMenu()
		end
	end
end

---------------------------------------------------------------------------
-- Friends phone app (spec 46, 47, 44, 97)
---------------------------------------------------------------------------
local TABS = { "Friends", "Requests", "Nearby", "Me", "Privacy" }
local currentTab = "Friends"
local appContent: ScrollingFrame? = nil
local renderApp: () -> ()

openFriendsTab = function(tab: string)
	currentTab = tab
	Phone.setOpen(true)
	Phone.showPage("Friends")
end

local function sectionLabel(parent: Instance, order: number, text: string)
	UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = order, Parent = parent })
end

local function smallButton(parent: Instance, text: string, color: Color3, x: number, width: number, fn: () -> ()): TextButton
	local b = UI.button({ Text = text, TextSize = 12, BackgroundColor3 = color, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -x, 1, 0), Size = UDim2.fromOffset(width, 26), Parent = parent })
	b.Activated:Connect(fn)
	return b
end

local function emptyNote(parent: Instance, order: number, text: string)
	UI.label({ Text = text, TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 40), LayoutOrder = order, Parent = parent })
end

local function rerender()
	if Phone.isOpen() and Phone.currentPage() == "Friends" then
		renderApp()
	end
end

local function renderTabs(content: ScrollingFrame)
	local bar = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -16, 0, 30), LayoutOrder = 0, Parent = content }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local incoming = state and #state.incoming or 0
	for i, tab in TABS do
		local text = if tab == "Requests" and incoming > 0 then "Req (" .. incoming .. ")" else (if tab == "Requests" then "Req" else tab)
		local b = UI.button({
			Text = text,
			TextSize = 11,
			BackgroundColor3 = if tab == currentTab then colors.accent else colors.panelLight,
			Size = UDim2.new(1 / #TABS, -3, 1, 0),
			LayoutOrder = i,
			Parent = bar,
		})
		b.Activated:Connect(function()
			currentTab = tab
			renderApp()
		end)
	end
end

local function renderFriends(content: ScrollingFrame)
	local friends = state.friends
	local online = 0
	for _, f in friends do
		if f.online then
			online += 1
		end
	end
	sectionLabel(content, 1, string.format("FRIENDS  %d/%d  ·  %d HERE", #friends, state.maxFriends or SC.MAX_FRIENDS, online))

	-- add by username (reaches players on other servers / offline when DataStores work)
	local addCard = Phone.card(content, 74, 2)
	UI.label({ Text = "Add by Roblox username", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = addCard })
	local box = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "username",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		BackgroundColor3 = colors.panel,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, -66, 0, 28),
		Parent = addCard,
	}, { UI.corner(8), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })
	local addBtn = UI.button({ Text = "ADD", TextSize = 13, BackgroundColor3 = GOOD, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 20), Size = UDim2.fromOffset(58, 28), Parent = addCard })
	addBtn.Activated:Connect(function()
		local name = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			return
		end
		if actToast("FRIENDS", "addByName", name) then
			box.Text = ""
		end
	end)

	if #friends == 0 then
		emptyNote(content, 3, "No friends yet. Walk up to someone and press ••• (T) to add them, or use Nearby.")
	end
	for i, f in friends do
		local row = Phone.card(content, 76, 10 + i)
		local name = tostring(f.name) .. (if f.robloxFriend then "  ⭐" else "")
		UI.label({ Text = name, Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -40, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local lvl = if f.level then "  ·  LV " .. f.level else ""
		UI.label({ Text = (if f.online then "● " else "○ ") .. statusText(f.status) .. lvl, TextSize = 12, TextColor3 = statusColor(f.status), Position = UDim2.fromOffset(0, 17), Size = UDim2.new(1, 0, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local userId = f.userId
		local x = 0
		local armed = false
		local removeBtn: TextButton
		removeBtn = smallButton(row, "✕", DIM, x, 30, function()
			if not armed then
				armed = true
				removeBtn.Text = "Sure?"
				removeBtn.Size = UDim2.fromOffset(50, 26)
				removeBtn.BackgroundColor3 = colors.danger
				return
			end
			actToast("FRIENDS", "remove", userId)
		end)
		x += 56
		smallButton(row, "Profile", BLUE, x, 58, function()
			Social.openProfile(userId)
		end)
		x += 62
		if f.online and f.canLocate then
			smallButton(row, "GPS", Color3.fromRGB(240, 150, 40), x, 44, function()
				local ok, message, info = act("locate", userId)
				if ok and type(info) == "table" and typeof(info.position) == "Vector3" then
					Phone.setGPS(tostring(info.name), info.position)
				else
					HUD.push("GPS", message or "Couldn't find them.")
				end
			end)
			x += 48
		end
		local target = if f.online then Players:GetPlayerByUserId(userId) else nil
		if target then
			smallButton(row, "•••", DIM, x, 40, function()
				Social.openMenu(target)
			end)
		end
	end

	-- Roblox friends here who aren't in-game friends yet
	local order = 500
	local shown = false
	for _, id in state.robloxHere or {} do
		local other = Players:GetPlayerByUserId(id)
		if other and not friendSet[id] and not Social.isBlocked(id) then
			if not shown then
				sectionLabel(content, order, "ROBLOX FRIENDS IN THIS SERVER")
				shown = true
			end
			order += 1
			local row = Phone.card(content, 48, order)
			UI.label({ Text = "⭐ " .. other.DisplayName, Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -70, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
			local add = smallButton(row, "Add", GOOD, 0, 52, function()
				actToast("FRIENDS", "request", id)
			end)
			add.AnchorPoint = Vector2.new(1, 0.5)
			add.Position = UDim2.new(1, 0, 0.5, 0)
		end
	end
end

local function renderRequests(content: ScrollingFrame)
	sectionLabel(content, 1, "INCOMING")
	if #state.incoming == 0 then
		emptyNote(content, 2, "No friend requests right now.")
	end
	for i, r in state.incoming do
		local row = Phone.card(content, 76, 2 + i)
		UI.label({ Text = tostring(r.name), Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		UI.label({ Text = "@" .. tostring(r.username or "") .. (if r.t then "  ·  " .. UI.timeAgo(r.t) else ""), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 14), Parent = row })
		local userId = r.userId
		smallButton(row, "Accept", GOOD, 0, 62, function()
			actToast("FRIENDS", "accept", userId)
		end)
		smallButton(row, "Decline", DIM, 66, 62, function()
			actToast("FRIENDS", "decline", userId)
		end)
		smallButton(row, "Profile", BLUE, 132, 58, function()
			Social.openProfile(userId)
		end)
	end
	sectionLabel(content, 200, "SENT")
	if #state.outgoing == 0 then
		emptyNote(content, 201, "You haven't sent any requests.")
	end
	for i, r in state.outgoing do
		local row = Phone.card(content, 48, 201 + i)
		UI.label({ Text = tostring(r.name), Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -80, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		UI.label({ Text = if r.t then "sent " .. UI.timeAgo(r.t) else "", TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -80, 0, 14), Parent = row })
		local userId = r.userId
		local b = smallButton(row, "Cancel", DIM, 0, 62, function()
			actToast("FRIENDS", "cancel", userId)
		end)
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, 0, 0.5, 0)
	end
end

local function renderNearby(content: ScrollingFrame)
	local others = {}
	for _, other in Players:GetPlayers() do
		if other ~= player and not hiddenSet[other.UserId] then
			table.insert(others, { player = other, dist = distanceTo(other) })
		end
	end
	table.sort(others, function(a, b)
		return a.dist < b.dist
	end)
	sectionLabel(content, 1, "PLAYERS IN THIS SERVER (" .. #others .. ")")
	if #others == 0 then
		emptyNote(content, 2, "Nobody else is in this city right now.")
	end
	local pending = {}
	for _, r in state.outgoing do
		pending[r.userId] = "sent"
	end
	for _, r in state.incoming do
		pending[r.userId] = "incoming"
	end
	for i, entry in others do
		local other: Player = entry.player
		local id = other.UserId
		local row = Phone.card(content, 76, 2 + i)
		local badge = (if friendSet[id] then "  🤝" else "") .. (if table.find(state.robloxHere or {}, id) then "  ⭐" else "")
		UI.label({ Text = other.DisplayName .. badge, Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local dist = if entry.dist < math.huge then math.floor(entry.dist / 3.57) .. "m away" else "far away"
		local status = other:GetAttribute("SocialStatus")
		local line = "LV " .. tostring(other:GetAttribute("Level") or 1) .. "  ·  " .. dist
		if type(status) == "string" and status ~= "" then
			line ..= "  ·  " .. statusText(status)
		end
		UI.label({ Text = line, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		smallButton(row, "Profile", BLUE, 0, 58, function()
			Social.openProfile(id)
		end)
		if blockedSet[id] then
			smallButton(row, "Unblock", DIM, 62, 64, function()
				unblockUser(id)
			end)
		elseif not friendSet[id] then
			if pending[id] == "sent" then
				UI.label({ Text = "Request sent", TextSize = 11, TextColor3 = colors.subtext, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -64, 1, -6), Size = UDim2.fromOffset(90, 14), TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
			else
				smallButton(row, if pending[id] == "incoming" then "Accept" else "Add Friend", GOOD, 62, 80, function()
					actToast("FRIENDS", if pending[id] == "incoming" then "accept" else "request", id)
				end)
			end
		end
	end
end

local function cycle(list: { any }, current: any): any
	local i = table.find(list, current) or 0
	return list[i % #list + 1]
end

local function renderMe(content: ScrollingFrame)
	local profile = state.profile
	local view = UI.button({ Text = "VIEW MY PROFILE", TextSize = 14, BackgroundColor3 = BLUE, Size = UDim2.new(1, -20, 0, 36), LayoutOrder = 1, Parent = content })
	view.Activated:Connect(function()
		Social.openProfile(player.UserId)
	end)

	-- Status (spec 47)
	sectionLabel(content, 2, "MY STATUS")
	local rows = math.ceil(#SC.STATUSES / 2)
	local statusCard = Phone.card(content, 26 + rows * 34, 3)
	for i, st in SC.STATUSES do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		local b = UI.button({
			Text = (if st.icon ~= "" then st.icon .. " " else "") .. st.label,
			TextSize = 11,
			TextWrapped = true,
			BackgroundColor3 = if state.status == st.id then colors.accent else colors.panel,
			Position = UDim2.new(col * 0.5, if col == 1 then 3 else 0, 0, row * 34),
			Size = UDim2.new(0.5, -3, 0, 30),
			Parent = statusCard,
		})
		b.Activated:Connect(function()
			if act("status", st.id) then
				fetchState()
				renderApp()
			end
		end)
	end
	UI.label({ Text = "Auto shows what you're doing. Do Not Disturb blocks invites and calls.", TextSize = 11, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 28), LayoutOrder = 4, Parent = content })

	-- Banner colour
	sectionLabel(content, 10, "PROFILE BANNER")
	local bannerCard = Phone.card(content, 56, 11)
	for i, color in SC.BANNERS do
		local swatch = UI.new("TextButton", { Text = "", AutoButtonColor = true, BackgroundColor3 = color, Position = UDim2.fromOffset((i - 1) * 29, 2), Size = UDim2.fromOffset(25, 28), Parent = bannerCard }, { UI.corner(6) })
		if profile.banner == i then
			UI.stroke(Color3.new(1, 1, 1), 2).Parent = swatch
		end
		swatch.Activated:Connect(function()
			if act("profile", "banner", i) then
				fetchState()
				renderApp()
			end
		end)
	end

	-- Title (unlocked from level / reputation / basketball)
	sectionLabel(content, 20, "TITLE")
	local titleCard = Phone.card(content, 0, 21)
	titleCard.AutomaticSize = Enum.AutomaticSize.Y
	UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = titleCard })
	local unlocked = {}
	for _, id in state.titles or {} do
		unlocked[id] = true
	end
	for i, t in SC.TITLES do
		local isOn = unlocked[t.id] == true
		local b = UI.button({
			Text = if isOn then t.id else ("🔒 " .. t.id .. "  ·  " .. SC.titleRequirement(t)),
			TextSize = 12,
			AutoButtonColor = isOn,
			BackgroundColor3 = if profile.title == t.id then colors.accent elseif isOn then colors.panel else Color3.fromRGB(28, 28, 34),
			TextColor3 = if isOn then colors.text else colors.subtext,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = i,
			Parent = titleCard,
		})
		if isOn then
			b.Activated:Connect(function()
				if act("profile", "title", t.id) then
					fetchState()
					renderApp()
				end
			end)
		end
	end

	-- Favourite activity + featured stat (tap to cycle)
	sectionLabel(content, 30, "SHOWCASE")
	local showCard = Phone.card(content, 92, 31)
	UI.label({ Text = "Favourite activity", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(0.5, 0, 0, 28), Parent = showCard })
	local fav = UI.button({ Text = if profile.favorite == "None" then "Not set ›" else tostring(profile.favorite) .. " ›", TextSize = 12, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.5, 0, 0, 28), Parent = showCard })
	fav.Activated:Connect(function()
		if act("profile", "favorite", cycle(SC.FAVORITES, profile.favorite)) then
			fetchState()
			renderApp()
		end
	end)
	UI.label({ Text = "Featured stat", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(0.5, 0, 0, 28), Parent = showCard })
	local featuredIds = {}
	for _, f in SC.FEATURED do
		table.insert(featuredIds, f.id)
	end
	local featured = SC.FEATURED_BY_ID[profile.featured] or SC.FEATURED[1]
	local feat = UI.button({ Text = featured.label .. " ›", TextSize = 12, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 34), Size = UDim2.new(0.5, 0, 0, 28), Parent = showCard })
	feat.Activated:Connect(function()
		if act("profile", "featured", cycle(featuredIds, profile.featured)) then
			fetchState()
			renderApp()
		end
	end)

	-- Bio (filtered by the server before anyone sees it)
	sectionLabel(content, 40, "BIO")
	local bioCard = Phone.card(content, 120, 41)
	local bioBox = UI.new("TextBox", {
		Text = tostring(profile.bio or ""),
		PlaceholderText = "Say something about yourself...",
		ClearTextOnFocus = false,
		MultiLine = true,
		TextWrapped = true,
		Font = UI.FONT,
		TextSize = 13,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		BackgroundColor3 = colors.panel,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 60),
		Parent = bioCard,
	}, { UI.corner(8), UI.padding(6) })
	local countLabel = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 66), Size = UDim2.new(0.5, 0, 0, 14), Parent = bioCard })
	local function updateCount()
		local n = utf8.len(bioBox.Text) or #bioBox.Text
		countLabel.Text = n .. " / " .. SC.BIO_MAX
		countLabel.TextColor3 = if n > SC.BIO_MAX then colors.danger else colors.subtext
	end
	bioBox:GetPropertyChangedSignal("Text"):Connect(updateCount)
	updateCount()
	local save = UI.button({ Text = "SAVE BIO", TextSize = 12, BackgroundColor3 = GOOD, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), Size = UDim2.fromOffset(90, 28), Parent = bioCard })
	save.Activated:Connect(function()
		if actToast("PROFILE", "profile", "bio", bioBox.Text) then
			HUD.push("PROFILE", if bioBox.Text == "" then "Bio cleared." else "Bio saved.")
			fetchState()
		end
	end)
end

local function renderPrivacy(content: ScrollingFrame)
	local privacy = state.privacy
	sectionLabel(content, 1, "WHO CAN...")
	for i, kind in SC.PRIVACY_KINDS do
		local row = Phone.card(content, 44, 1 + i)
		UI.label({ Text = kind.label, Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(0.5, 0, 1, 0), Parent = row })
		local value = privacy[kind.id] or "Everyone"
		local b = UI.button({
			Text = value .. " ›",
			TextSize = 12,
			BackgroundColor3 = if value == "Nobody" then colors.danger elseif value == "Everyone" then GOOD else BLUE,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(104, 28),
			Parent = row,
		})
		b.Activated:Connect(function()
			if act("privacy", kind.id, cycle(SC.PRIVACY_VALUES, value)) then
				fetchState()
				renderApp()
			end
		end)
	end

	local visRow = Phone.card(content, 44, 20)
	UI.label({ Text = "Profile visibility", Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(0.5, 0, 1, 0), Parent = visRow })
	local vis = privacy.profile or "Public"
	local visBtn = UI.button({ Text = vis .. " ›", TextSize = 12, BackgroundColor3 = if vis == "Public" then GOOD elseif vis == "Private" then colors.danger else BLUE, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(104, 28), Parent = visRow })
	visBtn.Activated:Connect(function()
		if act("privacy", "profile", cycle(SC.PROFILE_VISIBILITY, vis)) then
			fetchState()
			renderApp()
		end
	end)

	for i, toggle in { { key = "showStatus", label = "Show my status" }, { key = "shareLocation", label = "Friends can GPS to me" } } do
		local row = Phone.card(content, 44, 20 + i)
		UI.label({ Text = toggle.label, Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(1, -70, 1, 0), Parent = row })
		local on = privacy[toggle.key] == true
		local b = UI.button({ Text = if on then "ON" else "OFF", TextSize = 12, BackgroundColor3 = if on then GOOD else colors.panel, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(56, 28), Parent = row })
		b.Activated:Connect(function()
			if act("privacy", toggle.key, not on) then
				fetchState()
				renderApp()
			end
		end)
	end

	sectionLabel(content, 40, "BLOCKED (" .. #state.blocked .. ")")
	if #state.blocked == 0 then
		emptyNote(content, 41, "You haven't blocked anyone.")
	end
	for i, b in state.blocked do
		local row = Phone.card(content, 44, 41 + i)
		UI.label({ Text = tostring(b.name), Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(1, -80, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local userId = b.userId
		local btn = UI.button({ Text = "Unblock", TextSize = 12, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(70, 28), Parent = row })
		btn.Activated:Connect(function()
			unblockUser(userId)
		end)
	end

	sectionLabel(content, 400, "MUTED (" .. #state.muted .. ")")
	if #state.muted == 0 then
		emptyNote(content, 401, "Muting hides someone's messages and invites from you, and mutes their voice for you where Roblox's audio API is on.")
	end
	for i, m in state.muted do
		local row = Phone.card(content, 44, 401 + i)
		UI.label({ Text = tostring(m.name), Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(1, -80, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
		local userId = m.userId
		local btn = UI.button({ Text = "Unmute", TextSize = 12, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(70, 28), Parent = row })
		btn.Activated:Connect(function()
			if actToast("MUTE", "unmute", userId) then
				fetchState()
			end
		end)
	end

	local help = Phone.card(content, 74, 800)
	UI.label({
		Text = "To report someone, open the Roblox menu (Esc / ☰) → Report. Blocking here hides them from you in City Grind; Roblox's block also applies across Roblox.",
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = colors.subtext,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.fromScale(1, 1),
		Parent = help,
	})
end

renderApp = function()
	local content = appContent
	if not content then
		return
	end
	Phone.clear(content)
	renderTabs(content)
	if not state then
		emptyNote(content, 1, "Loading your friends...")
		return
	end
	local renderers = { Friends = renderFriends, Requests = renderRequests, Nearby = renderNearby, Me = renderMe, Privacy = renderPrivacy }
	local ok, err = pcall(renderers[currentTab] or renderFriends, content)
	if not ok then
		warn("[CityGrind] Friends app render failed:", err)
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Social.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindSocial",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 8,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildMenu()
	buildProfileCard()
	buildReport()
	buildEmoteCard()

	Phone.addApp({ id = "Friends", label = "Friends", icon = "🤝", color = Color3.fromRGB(60, 150, 230) }, function(content)
		appContent = content
		return function()
			renderApp()
			task.spawn(function()
				fetchState()
				rerender()
			end)
		end
	end)

	task.spawn(function()
		remotes = shared:WaitForChild("Remotes")
		local r = remotes :: Instance
		SocialAction = r:WaitForChild("SocialAction") :: RemoteFunction
		SocialProfile = r:WaitForChild("SocialProfile") :: RemoteFunction
		SocialEmote = r:WaitForChild("SocialEmote") :: RemoteEvent
		local SocialEvent = r:WaitForChild("SocialEvent") :: RemoteEvent
		SocialEvent.OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any)
			if kind == "State" then
				applyState(a)
				-- live refresh, except while typing on the Me tab
				if currentTab ~= "Me" then
					rerender()
				end
			elseif kind == "EmoteRequest" and type(a) == "number" and type(b) == "string" and type(c) == "string" then
				showEmoteRequest(a, b, c)
			end
		end)
		if not player:GetAttribute("DataLoaded") then
			player:GetAttributeChangedSignal("DataLoaded"):Wait()
		end
		fetchState()
	end)

	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(other)
		local prompt = prompts[other]
		if prompt then
			prompt:Destroy()
			prompts[other] = nil
		end
		if menuTarget == other then
			closeMenu()
		end
	end)
	Social.changed.Event:Connect(refreshVisibility)

	-- keep visibility right as characters respawn, and refresh the
	-- Friends / Nearby lists while they're on screen
	task.spawn(function()
		local tick = 0
		while true do
			task.wait(1)
			refreshVisibility()
			if menuTarget and (not menuTarget.Parent or distanceTo(menuTarget) > 60) then
				closeMenu()
			end
			tick += 1
			if tick % 6 == 0 and Phone.isOpen() and Phone.currentPage() == "Friends" and (currentTab == "Friends" or currentTab == "Nearby") then
				task.spawn(function()
					fetchState()
					rerender()
				end)
			end
		end
	end)
end

return Social
