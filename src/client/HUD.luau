-- CITY GRIND: on-screen HUD. Cash, level/XP, reputation rank, stamina,
-- run tracker, notification toasts and the level-up / rank-up banner. Every
-- number shown here is read from server-owned Player attributes; the client
-- never decides them.
--
-- Layout API (Phase 8): every always-on-screen chip or panel registers with
--   HUD.slot(slotName, frame, priority)
-- and HUD stacks the registered frames of one screen edge without overlap.
-- Slots: "topRight" (under the stats card), "topCenter" (above the toasts),
-- "left" (middle of the left edge), "bottomCenter" (stacked up from the
-- bottom). A lower priority sits closer to the slot's screen edge; hidden
-- frames (Visible = false) take no space. Slotted frames live in the HUD
-- ScreenGui, so HUD.setVisible(false) (cinematics, photo mode) hides them all,
-- and they scale with the viewport (phones, small windows) through HUD.scale().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local Movement = require(script.Parent:WaitForChild("Movement"))
local remotes = ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Remotes")

local player = Players.LocalPlayer
local colors = UI.colors

local HUD = {}

-- Notification store shared with the phone.
HUD.notifications = {} :: { { title: string, body: string, time: number } }
HUD.notificationAdded = Instance.new("BindableEvent")
HUD.unread = 0

local gui: ScreenGui
local toastHolder: Frame
local notifySound: Sound

local MAX_TOASTS = 3
local TOAST_SECONDS = 4

---------------------------------------------------------------------------
-- Layout slots
---------------------------------------------------------------------------
type SlotDef = { anchor: Vector2, position: UDim2, size: UDim2, h: Enum.HorizontalAlignment, v: Enum.VerticalAlignment, reverse: boolean }

local SLOT_DEFS: { [string]: SlotDef } = {
	-- top-right, clear of Roblox's chat window in the top-left
	topRight = {
		anchor = Vector2.new(1, 0),
		position = UDim2.new(1, -12, 0, 12),
		size = UDim2.new(0, 250, 1, -24),
		h = Enum.HorizontalAlignment.Right,
		v = Enum.VerticalAlignment.Top,
		reverse = false,
	},
	topCenter = {
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 12),
		size = UDim2.new(0, 330, 0.7, 0),
		h = Enum.HorizontalAlignment.Center,
		v = Enum.VerticalAlignment.Top,
		reverse = false,
	},
	left = {
		anchor = Vector2.new(0, 0.5),
		position = UDim2.new(0, 12, 0.5, 20),
		size = UDim2.new(0, 260, 0.62, 0),
		h = Enum.HorizontalAlignment.Left,
		v = Enum.VerticalAlignment.Center,
		reverse = false,
	},
	bottomCenter = {
		anchor = Vector2.new(0.5, 1),
		position = UDim2.new(0.5, 0, 1, -16),
		size = UDim2.new(0, 400, 0.6, 0),
		h = Enum.HorizontalAlignment.Center,
		v = Enum.VerticalAlignment.Bottom,
		reverse = true, -- lowest priority at the very bottom
	},
}

local slots: { [string]: Frame } = {}
local slotScales: { UIScale } = {}
local pendingSlots: { { name: string, frame: GuiObject, priority: number } } = {}
local hudScale = 1

-- Viewport-based scale: small windows and phones shrink the panels so they
-- don't cover the screen; big screens grow a little. Touch screens never go
-- as small as desktop windows so buttons stay comfortable to tap.
local function computeScale(): number
	local camera = Workspace.CurrentCamera
	local vp = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	if vp.X < 2 or vp.Y < 2 then
		return 1
	end
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local s = math.min(vp.Y / 760, vp.X / 1100)
	if touchOnly then
		return math.clamp(s * 1.15, 0.8, 1.1)
	end
	return math.clamp(s, 0.7, 1.2)
end

local function applyScale()
	hudScale = computeScale()
	for _, s in slotScales do
		s.Scale = hudScale
	end
end

-- The current HUD scale (1 = designed size). Other modules can use it for
-- panels that stay outside the slots.
function HUD.scale(): number
	return hudScale
end

local function buildSlot(name: string, def: SlotDef): Frame
	local frame = UI.new("Frame", {
		Name = "Slot_" .. name,
		BackgroundTransparency = 1,
		AnchorPoint = def.anchor,
		Position = def.position,
		Size = def.size,
		Parent = gui,
	}, {
		UI.new("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = def.h,
			VerticalAlignment = def.v,
		}),
	})
	-- the slot frames themselves never eat clicks meant for the world
	frame.Active = false
	local s = UI.new("UIScale", { Scale = hudScale, Parent = frame })
	table.insert(slotScales, s)
	slots[name] = frame
	return frame
end

local function place(name: string, frame: GuiObject, priority: number)
	local def = SLOT_DEFS[name]
	local container = slots[name]
	if not def or not container then
		warn("[CityGrind] HUD.slot: unknown slot " .. tostring(name))
		return
	end
	frame.AnchorPoint = Vector2.zero
	frame.Position = UDim2.new()
	frame.LayoutOrder = if def.reverse then -priority else priority
	frame.Parent = container
end

-- Registers an always-on-screen frame with a HUD slot (see the header).
-- Safe to call before HUD.start(); the frame is placed once the HUD exists.
function HUD.slot(name: string, frame: GuiObject, priority: number?)
	if gui then
		place(name, frame, priority or 50)
	else
		table.insert(pendingSlots, { name = name, frame = frame, priority = priority or 50 })
	end
end

---------------------------------------------------------------------------
-- Toasts
---------------------------------------------------------------------------
local toastSeq = 0
local liveToasts: { { card: Frame, title: string, body: string, count: number, label: TextLabel, closing: boolean, expires: number } } = {}

local function closeToast(entry: any)
	if entry.closing then
		return
	end
	entry.closing = true
	local i = table.find(liveToasts, entry)
	if i then
		table.remove(liveToasts, i)
	end
	local card = entry.card
	local info = TweenInfo.new(0.3)
	for _, d in card:GetDescendants() do
		if d:IsA("TextLabel") then
			TweenService:Create(d, info, { TextTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
	local fade = TweenService:Create(card, info, { BackgroundTransparency = 1 })
	fade:Play()
	task.delay(0.32, function()
		card:Destroy()
	end)
end

local function toast(title: string, body: string)
	-- the same message again while it is still up: count it instead of stacking
	for _, entry in liveToasts do
		if entry.title == title and entry.body == body and not entry.closing then
			entry.count += 1
			entry.label.Text = title .. "  ×" .. entry.count
			entry.expires = os.clock() + TOAST_SECONDS
			return
		end
	end
	toastSeq += 1
	local card = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.08,
		Size = UDim2.new(1, 0, 0, 58),
		LayoutOrder = -toastSeq, -- newest on top
		Parent = toastHolder,
	}, {
		UI.corner(12),
		UI.stroke(colors.accent, 1.5, 0.3),
		UI.padding(10),
	})
	local titleLabel = UI.label({ Text = title, Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = colors.accent, Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	UI.label({ Text = body, TextSize = 14, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 20), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	-- slide in
	local scale = UI.new("UIScale", { Scale = 0.85, Parent = card })
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	local entry = { card = card, title = title, body = body, count = 1, label = titleLabel, closing = false, expires = os.clock() + TOAST_SECONDS }
	table.insert(liveToasts, entry)
	-- stacking limit: the oldest ones leave early
	while #liveToasts > MAX_TOASTS do
		closeToast(liveToasts[1])
	end
	task.spawn(function()
		while not entry.closing and os.clock() < entry.expires do
			task.wait(entry.expires - os.clock() + 0.05)
		end
		closeToast(entry)
	end)
end

local function remember(title: string, body: string)
	table.insert(HUD.notifications, 1, { title = title, body = body, time = os.time() })
	if #HUD.notifications > 50 then
		table.remove(HUD.notifications)
	end
	HUD.unread += 1
end

local function playNotify()
	if notifySound and player:GetAttribute("NotificationSounds") ~= false then
		local vol = player:GetAttribute("VolSFX")
		notifySound.Volume = 0.5 * (if type(vol) == "number" then math.clamp(vol, 0, 1) else 1)
		if notifySound.Volume > 0 then
			notifySound:Play()
		end
	end
end

function HUD.push(title: string, body: string)
	remember(title, body)
	if toastHolder then
		toast(title, body)
	end
	playNotify()
	HUD.notificationAdded:Fire()
end

function HUD.markRead()
	HUD.unread = 0
	HUD.notificationAdded:Fire()
end

-- Hides / shows the whole HUD layer: stats, toasts and every slotted chip.
-- Story cinematics and the photo camera call this.
function HUD.setVisible(visible: boolean)
	if gui then
		gui.Enabled = visible
	end
end

---------------------------------------------------------------------------
-- Level-up / rank-up banner
---------------------------------------------------------------------------
-- These server notifications get the big banner instead of a plain toast
-- (they still land in the phone's Alerts).
local BANNER_TITLES = { ["LEVEL UP"] = true, ["NEW RANK"] = true, ["FAME UP"] = true }
local bannerQueue: { { kicker: string, big: string, sub: string, color: Color3 } } = {}
local bannerBusy = false
local milestonesArmed = false

local function showBanner(b: { kicker: string, big: string, sub: string, color: Color3 })
	local root = UI.new("Frame", {
		Name = "Banner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.34),
		Size = UDim2.fromOffset(420, 120),
		ZIndex = 40,
		Parent = gui,
	})
	local scale = UI.new("UIScale", { Scale = 0.6 * hudScale, Parent = root })
	local plate = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.12,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 96),
		ZIndex = 40,
		Parent = root,
	}, { UI.corner(18), UI.stroke(b.color, 2.5, 0.1) })
	local gradient = UI.new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, colors.panel),
			ColorSequenceKeypoint.new(0.5, b.color:Lerp(colors.panel, 0.55)),
			ColorSequenceKeypoint.new(1, colors.panel),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = plate,
	})
	local kicker = UI.label({ Text = b.kicker, Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = b.color, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 16), ZIndex = 41, Parent = plate })
	local big = UI.label({ Text = b.big, Font = UI.FONT_BLACK, TextSize = 38, TextStrokeTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 40), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 41, Parent = plate })
	local sub = UI.label({ Text = b.sub, Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 41, Parent = plate })

	playNotify()
	TweenService:Create(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = hudScale }):Play()
	TweenService:Create(gradient, TweenInfo.new(1.6, Enum.EasingStyle.Sine), { Offset = Vector2.new(1, 0) }):Play()
	task.wait(3.2)
	local info = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(scale, info, { Scale = 0.8 * hudScale }):Play()
	TweenService:Create(plate, info, { BackgroundTransparency = 1 }):Play()
	for _, l in { kicker, big, sub } do
		TweenService:Create(l, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
	for _, d in plate:GetChildren() do
		if d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
	task.wait(0.4)
	root:Destroy()
end

local function queueBanner(kicker: string, big: string, sub: string, color: Color3)
	-- a burst (several levels from one big reward) collapses to the latest
	for i = #bannerQueue, 1, -1 do
		if bannerQueue[i].kicker == kicker then
			table.remove(bannerQueue, i)
		end
	end
	table.insert(bannerQueue, { kicker = kicker, big = big, sub = sub, color = color })
	if bannerBusy then
		return
	end
	bannerBusy = true
	task.spawn(function()
		while #bannerQueue > 0 do
			local ok, err = pcall(showBanner, table.remove(bannerQueue, 1) :: any)
			if not ok then
				warn("[CityGrind] HUD banner failed:", err)
			end
		end
		bannerBusy = false
	end)
end

local function watchMilestones()
	-- only changes after the save has loaded (and settled) are celebrated
	local last = { Level = 0, Rank = "", FameLevel = "" }
	local function snapshot()
		last.Level = player:GetAttribute("Level") or 1
		last.Rank = player:GetAttribute("Rank") or ""
		last.FameLevel = player:GetAttribute("FameLevel") or ""
	end
	task.spawn(function()
		if not player:GetAttribute("DataLoaded") then
			player:GetAttributeChangedSignal("DataLoaded"):Wait()
		end
		task.wait(2)
		snapshot()
		milestonesArmed = true
	end)
	player:GetAttributeChangedSignal("Level"):Connect(function()
		local lv = player:GetAttribute("Level")
		if milestonesArmed and type(lv) == "number" and lv > last.Level then
			queueBanner("LEVEL UP", "LEVEL " .. lv, "Keep grinding: new jobs, cars and courts open up as you level.", colors.xp)
		end
		if type(lv) == "number" then
			last.Level = lv
		end
	end)
	player:GetAttributeChangedSignal("Rank"):Connect(function()
		local r = player:GetAttribute("Rank")
		if milestonesArmed and type(r) == "string" and r ~= last.Rank and r ~= "" then
			queueBanner("NEW RANK", string.upper(r), "That's what the city calls you now.", colors.accent)
		end
		last.Rank = if type(r) == "string" then r else last.Rank
	end)
	player:GetAttributeChangedSignal("FameLevel"):Connect(function()
		local f = player:GetAttribute("FameLevel")
		if milestonesArmed and type(f) == "string" and f ~= last.FameLevel and f ~= "" then
			queueBanner("FAME UP", string.upper(f), "More people know your name around the city.", Color3.fromRGB(255, 200, 60))
		end
		last.FameLevel = if type(f) == "string" then f else last.FameLevel
	end)
end

---------------------------------------------------------------------------
-- Stats card, stamina, run tracker, controls hint
---------------------------------------------------------------------------
local function buildStatsCard()
	local card = UI.new("Frame", {
		Name = "Stats",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		Size = UDim2.fromOffset(230, 92),
	}, { UI.corner(14), UI.padding(10) })
	HUD.slot("topRight", card, 0)

	local cash = UI.label({ Text = "$0", Font = UI.FONT_BLACK, TextSize = 24, TextColor3 = colors.cash, Size = UDim2.new(1, -60, 0, 26), Parent = card })
	local level = UI.new("TextLabel", {
		BackgroundColor3 = colors.xp,
		Text = "LV 1",
		Font = UI.FONT_BLACK,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 2),
		Size = UDim2.fromOffset(54, 22),
		Parent = card,
	}, { UI.corner(11) })
	local _, setXP = UI.bar({ Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 8), Parent = card }, colors.xp)
	local xpText = UI.label({ Text = "0 / 100 XP", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 14), Parent = card })
	local rank = UI.label({ Text = "Nobody", Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })

	local shownCash: number? = nil
	local function refresh()
		local newCash = player:GetAttribute("Cash") or 0
		if not player:GetAttribute("DataLoaded") then
			return
		end
		if newCash ~= shownCash then
			if shownCash then
				local diff = newCash - shownCash
				-- the +$/-$ pop floats just under the card
				local pop = UI.label({
					Text = (if diff > 0 then "+" else "") .. UI.formatCash(diff),
					Font = UI.FONT_BLACK,
					TextSize = 18,
					TextColor3 = if diff > 0 then colors.cash else colors.danger,
					TextStrokeTransparency = 0.6,
					TextXAlignment = Enum.TextXAlignment.Right,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, 0, 1, 6),
					Size = UDim2.fromOffset(140, 24),
					ZIndex = 5,
					Parent = card,
				})
				TweenService:Create(pop, TweenInfo.new(1.2), { Position = UDim2.new(1, 0, 1, 28), TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
				task.delay(1.3, pop.Destroy, pop)
			end
			shownCash = newCash
		end
		cash.Text = UI.formatCash(newCash)
		local lv = player:GetAttribute("Level") or 1
		level.Text = "LV " .. lv
		local xp = player:GetAttribute("XP") or 0
		local toNext = player:GetAttribute("XPToNext") or 100
		setXP(if lv >= 100 then 1 else xp / math.max(1, toNext))
		xpText.Text = if lv >= 100 then "MAX LEVEL" else string.format("%s / %s XP", UI.formatNumber(xp), UI.formatNumber(toNext))
		rank.Text = string.format("%s  ·  %s rep", player:GetAttribute("Rank") or "Nobody", UI.formatNumber(player:GetAttribute("Reputation") or 0))
	end
	for _, attr in { "Cash", "Level", "XP", "XPToNext", "Rank", "Reputation", "DataLoaded" } do
		player:GetAttributeChangedSignal(attr):Connect(refresh)
	end
	refresh()
end

local function buildStaminaBar()
	local holder = UI.new("Frame", {
		Name = "Stamina",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(260, 22),
		Visible = false,
	})
	HUD.slot("bottomCenter", holder, 0)
	UI.label({ Text = "STAMINA", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = holder })
	local bar, setFill = UI.bar({ Position = UDim2.fromOffset(0, 13), Size = UDim2.new(1, 0, 0, 9), Parent = holder }, colors.stamina)
	local fill = bar:FindFirstChild("Fill") :: Frame
	-- read every frame (it drains smoothly) but only touch the GUI when it changed
	local lastFrac, lastExhausted, lastVisible = -1, false, false
	RunService.RenderStepped:Connect(function()
		local s, maxS, exhausted = Movement.getStamina()
		local visible = s < maxS - 0.5 or Movement.isSprinting()
		if visible ~= lastVisible then
			lastVisible = visible
			holder.Visible = visible
		end
		if not visible then
			return
		end
		local frac = math.floor(s / maxS * 200 + 0.5) / 200
		if frac ~= lastFrac then
			lastFrac = frac
			setFill(frac)
		end
		if exhausted ~= lastExhausted then
			lastExhausted = exhausted
			fill.BackgroundColor3 = if exhausted then colors.danger else colors.stamina
		end
	end)
end

-- Shows the run timer and highlights the next checkpoint arch.
local function buildRunTracker()
	local panel = UI.new("Frame", {
		Name = "RunTracker",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		Size = UDim2.fromOffset(220, 54),
		Visible = false,
	}, { UI.corner(12), UI.padding(8) })
	HUD.slot("topCenter", panel, 20)
	local timer = UI.label({ Text = "0.0s", Font = UI.FONT_BLACK, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 22), Parent = panel })
	local nextLabel = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 14), Parent = panel })

	local highlight = Instance.new("Highlight")
	highlight.FillColor = colors.stamina
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.4
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = gui

	local function refresh()
		local nextIndex = player:GetAttribute("RunNext") or 0
		panel.Visible = nextIndex > 0
		local route = workspace:FindFirstChild("City") and workspace.City:FindFirstChild("RunRoute")
		if nextIndex == 0 or not route then
			highlight.Adornee = nil
			return
		end
		local count = #route:GetChildren()
		local target = if nextIndex > count then 1 else nextIndex
		highlight.Adornee = route:FindFirstChild("Checkpoint" .. target)
		nextLabel.Text = if target == 1 then "Head back to the FINISH" else "Next: Checkpoint " .. (target - 1)
	end
	player:GetAttributeChangedSignal("RunNext"):Connect(refresh)
	refresh()

	-- the timer shows tenths, so 10 Hz is all it needs
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		if panel.Visible then
			local started = player:GetAttribute("RunStartedAt") or 0
			timer.Text = string.format("%.1fs", workspace:GetServerTimeNow() - started)
		end
	end)
end

local function buildControlsHint()
	if not UserInputService.KeyboardEnabled then
		return
	end
	local hint = UI.label({
		Name = "ControlsHint",
		Text = "P Phone · Shift Sprint · C Crouch/Slide · E Interact\nClick Shoot · Q Pass · F Steal · T Player menu · . Emotes",
		TextSize = 12,
		TextColor3 = colors.subtext,
		TextStrokeTransparency = 0.6,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -10),
		Size = UDim2.fromOffset(380, 30),
		Parent = gui,
	})
	-- a reminder for new players, not permanent clutter: fades after a while
	task.delay(120, function()
		TweenService:Create(hint, TweenInfo.new(1.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.wait(1.6)
		hint.Visible = false
	end)
end

function HUD.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	notifySound = UI.new("Sound", { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Parent = SoundService })

	hudScale = computeScale()
	for name, def in SLOT_DEFS do
		buildSlot(name, def)
	end
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local cam = Workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
			applyScale()
		end
	end)

	-- toasts sit under whatever is in the top-centre slot
	toastHolder = UI.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	HUD.slot("topCenter", toastHolder, 100)

	for _, p in pendingSlots do
		place(p.name, p.frame, p.priority)
	end
	table.clear(pendingSlots)

	buildStatsCard()
	buildStaminaBar()
	buildRunTracker()
	buildControlsHint()
	watchMilestones()

	remotes:WaitForChild("Notify").OnClientEvent:Connect(function(title: string, body: string)
		if type(title) ~= "string" or type(body) ~= "string" then
			return
		end
		if BANNER_TITLES[title] and milestonesArmed then
			-- the banner (driven by the attribute change) celebrates it; keep the alert
			remember(title, body)
			HUD.notificationAdded:Fire()
			return
		end
		HUD.push(title, body)
	end)
end

return HUD
