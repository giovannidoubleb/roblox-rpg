-- CITY GRIND: quests client (spec 78, 79, 80, 113).
-- The phone's Quests app (Story / Daily / Weekly / Achievements / Login tabs),
-- the daily login popup on join and the achievement unlock banner. The server
-- tracks and validates everything; this module only shows its state and sends taps.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local QC = require(shared:WaitForChild("QuestsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Quests = {}

local APP_ID = "Quests"
local APP_COLOR = Color3.fromRGB(240, 170, 40)
local GOLD = Color3.fromRGB(255, 200, 60)
local TABS = { "Story", "Daily", "Weekly", "Achievements", "Login" }

local state: any = nil
local requestRemote: RemoteFunction? = nil
local appContent: ScrollingFrame? = nil
local tab = "Story"
local busy = false
local gui: ScreenGui? = nil
local popupShown = false
local popupEarliest = os.clock() + 5 -- give the Story a moment to start the first-join fly-over
local achievementSound: Sound? = nil

-- Fired whenever new quest state arrives (Story's tab listens too).
Quests.changed = Instance.new("BindableEvent")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function storyClient(): any
	local module = script.Parent:FindFirstChild("Story")
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

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

local function serverNow(): number
	-- server sent its os.time(); keep it ticking locally
	if state and state.serverNow and state.receivedAt then
		return state.serverNow + (os.clock() - state.receivedAt)
	end
	return os.time()
end

local render: () -> ()
local showLoginPopup: () -> ()

local function setState(newState: any)
	if type(newState) ~= "table" then
		return
	end
	newState.receivedAt = os.clock()
	if state == nil then
		popupEarliest = math.max(popupEarliest, os.clock() + 2)
	end
	state = newState
	Quests.changed:Fire()
	if appContent and Phone.isOpen() and Phone.currentPage() == APP_ID then
		render()
	end
	showLoginPopup()
end

local function request(action: string, a: any?, b: any?): (boolean, string?)
	if not requestRemote or busy then
		return false, nil
	end
	busy = true
	local ok, success, msg, newState = pcall(function()
		return (requestRemote :: RemoteFunction):InvokeServer(action, a, b)
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

local function rewardText(cash: number?, xp: number?, rep: number?): string
	local parts = {}
	if cash and cash > 0 then
		table.insert(parts, "$" .. QC.commas(cash))
	end
	if xp and xp > 0 then
		table.insert(parts, QC.commas(xp) .. " XP")
	end
	if rep and rep > 0 then
		table.insert(parts, rep .. " rep")
	end
	return table.concat(parts, "  ·  ")
end

---------------------------------------------------------------------------
-- App: tab bar
---------------------------------------------------------------------------
local function tabBar(content: ScrollingFrame)
	local bar = UI.new("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 62), LayoutOrder = 0, Parent = content }, {
		UI.new("UIGridLayout", { CellSize = UDim2.new(1 / 3, -4, 0, 28), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, name in TABS do
		local selected = name == tab
		local b = UI.button({
			Text = name,
			TextSize = if #name > 8 then 10 else 12,
			LayoutOrder = i,
			BackgroundColor3 = if selected then APP_COLOR else colors.panelLight,
			TextColor3 = if selected then Color3.fromRGB(25, 20, 10) else colors.text,
			Parent = bar,
		})
		b.Activated:Connect(function()
			tab = name
			render()
		end)
	end
end

local function message(content: Instance, text: string, order: number)
	local c = Phone.card(content, 50, order)
	UI.label({ Text = text, TextSize = 13, TextColor3 = colors.subtext, TextWrapped = true, Size = UDim2.fromScale(1, 1), Parent = c })
end

---------------------------------------------------------------------------
-- App: quests
---------------------------------------------------------------------------
local function questCard(content: Instance, q: any, index: number, list: string, order: number)
	local c = Phone.card(content, 112, order)
	local done = q.progress >= q.goal
	if done and not q.claimed then
		UI.stroke(GOLD, 1.5, 0.2).Parent = c
	end
	UI.label({ Text = q.icon, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(28, 28), Parent = c })
	UI.label({ Text = q.text, Font = UI.FONT_BOLD, TextSize = 14, TextWrapped = true, Position = UDim2.fromOffset(34, 0), Size = UDim2.new(1, -34, 0, 34), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
	local _, setFill = UI.bar({ Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 0, 8), Parent = c }, if q.claimed then colors.subtext elseif done then GOLD else colors.xp)
	setFill(if q.goal > 0 then q.progress / q.goal else 1)
	UI.label({
		Text = QC.formatValue(q.metric, q.progress) .. " / " .. QC.formatValue(q.metric, q.goal),
		TextSize = 12,
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = c,
	})
	UI.label({ Text = rewardText(q.cash, q.xp, q.rep), TextSize = 12, TextColor3 = colors.cash, Font = UI.FONT_BOLD, Position = UDim2.fromOffset(0, 66), Size = UDim2.new(1, 0, 0, 14), Parent = c })

	local button = UI.button({ TextSize = 13, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(92, 24), Parent = c })
	if q.claimed then
		button.Text = "CLAIMED ✓"
		button.AutoButtonColor = false
		button.TextColor3 = colors.subtext
	elseif done then
		button.Text = "CLAIM"
		button.BackgroundColor3 = GOLD
		button.TextColor3 = Color3.fromRGB(30, 22, 5)
		button.Activated:Connect(function()
			local ok, msg = request("Claim", list, index)
			HUD.push(if ok then "QUEST COMPLETE" else "QUESTS", msg or "Try again.")
		end)
	elseif list == "daily" and state.rerollAvailable then
		button.Text = "↻ REROLL"
		button.Activated:Connect(function()
			local ok, msg = request("Reroll", index)
			HUD.push(if ok then "QUEST REROLLED" else "QUESTS", msg or "Try again.")
		end)
	else
		button.Text = "IN PROGRESS"
		button.AutoButtonColor = false
		button.TextColor3 = colors.subtext
		button.BackgroundTransparency = 0.5
	end
end

local function renderQuests(content: ScrollingFrame, list: string)
	local quests = if list == "daily" then state.daily else state.weekly
	local resetAt = if list == "daily" then state.dailyResetAt else state.weeklyResetAt
	local head = Phone.card(content, 46, 1)
	UI.label({ Text = if list == "daily" then "DAILY QUESTS" else "WEEKLY QUESTS", Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = APP_COLOR, Size = UDim2.new(1, 0, 0, 16), Parent = head })
	local sub = "New quests in " .. duration((resetAt or 0) - serverNow())
	if list == "daily" then
		sub ..= if state.rerollAvailable then "  ·  1 free reroll" else "  ·  reroll used"
	end
	UI.label({ Text = sub, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 14), Parent = head })
	if #quests == 0 then
		message(content, "No quests right now. Check back after the reset.", 2)
	end
	for i, q in quests do
		questCard(content, q, i, list, 1 + i)
	end
end

---------------------------------------------------------------------------
-- App: achievements
---------------------------------------------------------------------------
local function renderAchievements(content: ScrollingFrame)
	local unlocked, total = 0, 0
	local shown = {}
	for _, a in QC.ACHIEVEMENTS do
		local listed = state.ach[a.id] ~= nil or state.achProgress[a.id] ~= nil or a.metric == nil
		if a.needs == "districts" and not state.districts and not state.ach[a.id] then
			listed = false
		end
		if listed then
			total += 1
			if state.ach[a.id] then
				unlocked += 1
			end
			table.insert(shown, a)
		end
	end

	local head = Phone.card(content, 70, 1)
	UI.label({ Text = string.format("%d / %d UNLOCKED", unlocked, total), Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = GOLD, Size = UDim2.new(1, 0, 0, 18), Parent = head })
	local _, setFill = UI.bar({ Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 8), Parent = head }, GOLD)
	setFill(if total > 0 then unlocked / total else 0)
	local titles = if #state.titles > 0 then "Titles: " .. table.concat(state.titles, ", ") else "Some achievements unlock profile titles."
	UI.label({ Text = titles, TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 0, 26), TextYAlignment = Enum.TextYAlignment.Top, Parent = head })

	-- unlocked first (newest first), then locked by how close they are
	table.sort(shown, function(a, b)
		local ua, ub = state.ach[a.id], state.ach[b.id]
		if (ua ~= nil) ~= (ub ~= nil) then
			return ua ~= nil
		end
		if ua and ub then
			return ua > ub
		end
		local pa = if a.goal then (state.achProgress[a.id] or 0) / a.goal else 0
		local pb = if b.goal then (state.achProgress[b.id] or 0) / b.goal else 0
		return pa > pb
	end)

	for i, a in shown do
		local tierColor = QC.TIER_COLORS[a.tier] or colors.subtext
		local got = state.ach[a.id]
		local c = Phone.card(content, 74, 1 + i)
		UI.stroke(tierColor, 1.2, if got then 0.1 else 0.7).Parent = c
		UI.label({ Text = a.icon, TextSize = 24, TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = if got then 0 else 0.55, Size = UDim2.fromOffset(32, 32), Parent = c })
		UI.label({ Text = a.name, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = if got then colors.text else colors.subtext, Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -96, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
		UI.label({ Text = a.tier:upper(), Font = UI.FONT_BLACK, TextSize = 10, TextColor3 = tierColor, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(60, 14), Parent = c })
		UI.label({ Text = a.desc, TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, Position = UDim2.fromOffset(38, 17), Size = UDim2.new(1, -38, 0, 26), TextYAlignment = Enum.TextYAlignment.Top, Parent = c })
		local footer
		if got then
			footer = "Unlocked " .. os.date("%b %d, %Y", got) .. (if a.title then "  ·  Title: " .. a.title else "")
		elseif a.goal then
			local p = state.achProgress[a.id] or 0
			footer = QC.formatValue(a.metric :: string, math.min(p, a.goal)) .. " / " .. QC.formatValue(a.metric :: string, a.goal) .. "  ·  " .. rewardText(a.cash, a.xp, 0)
			local _, fill = UI.bar({ Position = UDim2.fromOffset(38, 44), Size = UDim2.new(1, -38, 0, 5), Parent = c }, tierColor)
			fill(p / a.goal)
		else
			footer = rewardText(a.cash, a.xp, 0) .. (if a.title then "  ·  Title: " .. a.title else "")
		end
		UI.label({ Text = footer, TextSize = 11, Font = UI.FONT_BOLD, TextColor3 = if got then tierColor else colors.cash, Position = UDim2.fromOffset(38, 51), Size = UDim2.new(1, -38, 0, 13), TextTruncate = Enum.TextTruncate.AtEnd, Parent = c })
	end
end

---------------------------------------------------------------------------
-- Daily login tiles (app tab and popup share them)
---------------------------------------------------------------------------
local function loginTiles(parent: Instance, cellWidth: number)
	local login = state.login
	local grid = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 2 * 86 + 6), Parent = parent }, {
		UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(cellWidth, 86), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	})
	for _, d in login.days do
		local claimedDay = d.day <= login.done
		local isNext = d.day == login.day and not login.claimed
		local tile = UI.new("Frame", {
			BackgroundColor3 = if isNext then Color3.fromRGB(70, 55, 20) elseif claimedDay then Color3.fromRGB(30, 50, 35) else colors.panelLight,
			LayoutOrder = d.day,
			Parent = grid,
		}, { UI.corner(10), UI.padding(4) })
		if isNext then
			UI.stroke(GOLD, 2).Parent = tile
		elseif d.day == 7 then
			UI.stroke(QC.TIER_COLORS.Platinum, 1, 0.4).Parent = tile
		end
		UI.label({ Text = "DAY " .. d.day, Font = UI.FONT_BLACK, TextSize = 10, TextColor3 = if isNext then GOLD else colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 12), Parent = tile })
		UI.label({ Text = if claimedDay then "✅" else d.icon, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 13), Size = UDim2.new(1, 0, 0, 26), Parent = tile })
		UI.label({ Text = d.text, TextSize = 9, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 41), Size = UDim2.new(1, 0, 1, -41), Parent = tile })
	end
	return grid
end

local function loginSummary(): string
	local login = state.login
	if login.claimed then
		return string.format("Day %d claimed. Next reward in %s. Miss a day and the streak restarts at Day 1.", login.day, duration((state.dailyResetAt or 0) - serverNow()))
	end
	return string.format("Day %d is ready to claim. Come back every day (UTC) to reach the Day 7 rare reward.", login.day)
end

local function claimLogin(after: (() -> ())?)
	local ok, msg = request("ClaimLogin")
	if not ok then
		HUD.push("DAILY REWARD", msg or "Try again.")
	end
	if after then
		after()
	end
end

local function renderLogin(content: ScrollingFrame)
	local head = Phone.card(content, 64, 1)
	UI.label({ Text = "DAILY LOGIN", Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = APP_COLOR, Size = UDim2.new(1, 0, 0, 16), Parent = head })
	UI.label({ Text = loginSummary(), TextSize = 11, TextWrapped = true, TextColor3 = colors.subtext, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 30), Parent = head })
	local holder = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 2 * 86 + 6), LayoutOrder = 2, Parent = content })
	loginTiles(holder, 60)
	if not state.login.claimed then
		local b = UI.button({ Text = "CLAIM DAY " .. state.login.day, TextSize = 16, BackgroundColor3 = GOLD, TextColor3 = Color3.fromRGB(30, 22, 5), Size = UDim2.new(1, -20, 0, 40), LayoutOrder = 3, Parent = content })
		b.Activated:Connect(function()
			claimLogin()
		end)
	end
	message(content, "Day 5 gives XP because every emote is already free. Day 6 pays the price of an underglow mod to spend at Paint & Mods.", 4)
end

---------------------------------------------------------------------------
-- App render
---------------------------------------------------------------------------
render = function()
	local content = appContent
	if not content then
		return
	end
	Phone.clear(content)
	tabBar(content)
	if tab == "Story" then
		local S = storyClient()
		if S and S.renderTab then
			S.renderTab(content, 1)
		else
			message(content, "The story isn't available right now.", 1)
		end
		return
	end
	if not state then
		message(content, "Loading your quests...", 1)
		return
	end
	if tab == "Daily" then
		renderQuests(content, "daily")
	elseif tab == "Weekly" then
		renderQuests(content, "weekly")
	elseif tab == "Achievements" then
		renderAchievements(content)
	else
		renderLogin(content)
	end
end

-- Lets the Story client open the app on its tab.
function Quests.open(tabName: string?)
	if tabName and table.find(TABS, tabName) then
		tab = tabName
	end
	Phone.setOpen(true)
	Phone.showPage(APP_ID)
end

function Quests.refresh()
	if appContent and Phone.isOpen() and Phone.currentPage() == APP_ID then
		render()
	end
end

---------------------------------------------------------------------------
-- Daily login popup (on join)
---------------------------------------------------------------------------
showLoginPopup = function()
	if popupShown or not gui or not state or state.login.claimed then
		return
	end
	if os.clock() < popupEarliest then
		task.delay(popupEarliest - os.clock() + 0.1, showLoginPopup)
		return
	end
	if not player:GetAttribute("DataLoaded") or player:GetAttribute("StoryCinematic") == true then
		return -- tried again when the intro fly-over ends (attribute listener)
	end
	popupShown = true
	local root = gui :: ScreenGui
	local shade = UI.new("Frame", { Name = "LoginPopup", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = root })
	local panel = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(330, 360),
		ZIndex = 11,
		Parent = shade,
	}, { UI.corner(18), UI.stroke(GOLD, 2, 0.2), UI.padding(14), UI.new("UISizeConstraint", { MaxSize = Vector2.new(330, 360) }) })
	UI.label({ Text = "DAILY REWARD", Font = UI.FONT_BLACK, TextSize = 22, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 26), Parent = panel })
	UI.label({ Text = loginSummary(), TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 32), Parent = panel })
	local holder = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 66), Size = UDim2.new(1, 0, 0, 2 * 86 + 6), Parent = panel })
	loginTiles(holder, 68)
	local function close()
		shade:Destroy()
	end
	local claim = UI.button({ Text = "CLAIM DAY " .. state.login.day, TextSize = 18, BackgroundColor3 = GOLD, TextColor3 = Color3.fromRGB(30, 22, 5), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(0.62, -4, 0, 44), Parent = panel })
	local later = UI.button({ Text = "LATER", TextSize = 15, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.new(0.38, -4, 0, 44), Parent = panel })
	for _, d in panel:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 12
		end
	end
	claim.Activated:Connect(function()
		claim.Text = "..."
		claimLogin(close)
	end)
	later.Activated:Connect(close)
	panel.Size = UDim2.fromOffset(300, 330)
	TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(330, 360) }):Play()
end

---------------------------------------------------------------------------
-- Achievement unlocked banner (its own look, and a phone notification)
---------------------------------------------------------------------------
local bannerQueue: { string } = {}
local bannerBusy = false

local function showAchievement(id: string)
	local a = QC.ACHIEVEMENT_BY_ID[id]
	if not a or not gui then
		return
	end
	local tierColor = QC.TIER_COLORS[a.tier] or GOLD
	local banner = UI.new("Frame", {
		Name = "Achievement",
		BackgroundColor3 = Color3.fromRGB(22, 18, 10),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -120),
		Size = UDim2.fromOffset(360, 86),
		ZIndex = 20,
		Parent = gui,
	}, { UI.corner(16), UI.stroke(tierColor, 2.5) })
	local gradient = UI.new("UIGradient", {
		Color = ColorSequence.new(tierColor:Lerp(Color3.new(0, 0, 0), 0.5), Color3.fromRGB(40, 32, 12)),
		Offset = Vector2.new(-1, 0),
		Parent = banner,
	})
	local medal = UI.new("TextLabel", {
		Text = a.icon,
		TextSize = 34,
		Font = UI.FONT,
		BackgroundColor3 = tierColor,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(62, 62),
		ZIndex = 21,
		Parent = banner,
	}, { UI.corner(31) })
	UI.label({ Text = "ACHIEVEMENT UNLOCKED  ·  " .. a.tier:upper(), Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = tierColor, Position = UDim2.fromOffset(86, 12), Size = UDim2.new(1, -96, 0, 14), ZIndex = 21, Parent = banner })
	UI.label({ Text = a.name, Font = UI.FONT_BLACK, TextSize = 22, Position = UDim2.fromOffset(86, 28), Size = UDim2.new(1, -96, 0, 24), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 21, Parent = banner })
	local reward = rewardText(a.cash, a.xp, 0) .. (if a.title then "  ·  Title: " .. a.title else "")
	UI.label({ Text = reward, Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.cash, Position = UDim2.fromOffset(86, 54), Size = UDim2.new(1, -96, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 21, Parent = banner })

	if achievementSound and player:GetAttribute("NotificationSounds") ~= false then
		achievementSound:Play()
	end
	TweenService:Create(banner, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 0, 150) }):Play()
	TweenService:Create(gradient, TweenInfo.new(1.4, Enum.EasingStyle.Sine), { Offset = Vector2.new(1, 0) }):Play()
	TweenService:Create(medal, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, true), { Rotation = 12 }):Play()

	-- phone notification (Alerts app) without a second toast
	table.insert(HUD.notifications, 1, { title = "ACHIEVEMENT: " .. a.name:upper(), body = a.desc .. "  " .. reward, time = os.time() })
	if #HUD.notifications > 50 then
		table.remove(HUD.notifications)
	end
	HUD.unread += 1
	HUD.notificationAdded:Fire()

	task.wait(4.2)
	local out = TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.new(0.5, 0, 0, -120) })
	out:Play()
	out.Completed:Wait()
	banner:Destroy()
end

local function queueAchievement(id: string)
	table.insert(bannerQueue, id)
	if bannerBusy then
		return
	end
	bannerBusy = true
	task.spawn(function()
		while #bannerQueue > 0 do
			showAchievement(table.remove(bannerQueue, 1) :: string)
		end
		bannerBusy = false
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function setup()
	local remotes = shared:WaitForChild("Remotes")
	requestRemote = remotes:WaitForChild("QuestsRequest") :: RemoteFunction
	local event = remotes:WaitForChild("QuestsEvent") :: RemoteEvent

	gui = UI.new("ScreenGui", {
		Name = "CityGrindQuests",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 8,
		Parent = player:WaitForChild("PlayerGui"),
	})
	achievementSound = UI.new("Sound", { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7, PlaybackSpeed = 1.35, Parent = SoundService })

	event.OnClientEvent:Connect(function(kind: any, payload: any)
		if kind == "State" then
			setState(payload)
		elseif kind == "Achievement" and type(payload) == "string" then
			queueAchievement(payload)
		end
	end)
	player:GetAttributeChangedSignal("StoryCinematic"):Connect(function()
		if player:GetAttribute("StoryCinematic") ~= true then
			task.delay(1.5, showLoginPopup)
		end
	end)

	if not player:GetAttribute("DataLoaded") then
		player:GetAttributeChangedSignal("DataLoaded"):Wait()
	end
	local ok, success, _, newState = pcall(function()
		return (requestRemote :: RemoteFunction):InvokeServer("Get")
	end)
	if ok and success and newState then
		setState(newState)
	end
end

function Quests.start()
	Phone.addApp({ id = APP_ID, label = "Quests", icon = "📜", color = APP_COLOR }, function(content: ScrollingFrame)
		appContent = content
		render()
		return function()
			render()
			task.spawn(request, "Get")
		end
	end)
	task.spawn(setup)
end

return Quests
