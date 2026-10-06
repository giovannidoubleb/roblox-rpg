-- CITY GRIND: on-screen HUD. Cash, level/XP, reputation rank, stamina,
-- run tracker and notification toasts. Every number shown here is read from
-- server-owned Player attributes; the client never decides them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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

local function toast(title: string, body: string)
	local card = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.08,
		Size = UDim2.new(1, 0, 0, 58),
		Parent = toastHolder,
	}, {
		UI.corner(12),
		UI.stroke(colors.accent, 1.5, 0.3),
		UI.padding(10),
		UI.label({ Text = title, Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = colors.accent, Size = UDim2.new(1, 0, 0, 16) }),
		UI.label({ Text = body, TextSize = 14, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 20), TextTruncate = Enum.TextTruncate.AtEnd }),
	})
	card.Position = UDim2.fromOffset(0, -10)
	task.delay(4, function()
		local fade = TweenService:Create(card, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
		for _, d in card:GetDescendants() do
			if d:IsA("TextLabel") then
				TweenService:Create(d, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
			elseif d:IsA("UIStroke") then
				TweenService:Create(d, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			end
		end
		fade:Play()
		fade.Completed:Wait()
		card:Destroy()
	end)
end

function HUD.push(title: string, body: string)
	table.insert(HUD.notifications, 1, { title = title, body = body, time = os.time() })
	if #HUD.notifications > 50 then
		table.remove(HUD.notifications)
	end
	HUD.unread += 1
	toast(title, body)
	if player:GetAttribute("NotificationSounds") ~= false then
		notifySound:Play()
	end
	HUD.notificationAdded:Fire()
end

function HUD.markRead()
	HUD.unread = 0
	HUD.notificationAdded:Fire()
end

function HUD.setVisible(visible: boolean)
	gui.Enabled = visible
end

local function buildStatsCard()
	local card = UI.new("Frame", {
		Name = "Stats",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(230, 92),
		Parent = gui,
	}, { UI.corner(14), UI.padding(10) })

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
	local rank = UI.label({ Text = "Nobody", Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 16), Parent = card })

	local shownCash: number? = nil
	local function refresh()
		local newCash = player:GetAttribute("Cash") or 0
		if not player:GetAttribute("DataLoaded") then
			return
		end
		if newCash ~= shownCash then
			if shownCash then
				local diff = newCash - shownCash
				local pop = UI.label({
					Text = (if diff > 0 then "+" else "") .. UI.formatCash(diff),
					Font = UI.FONT_BLACK,
					TextSize = 18,
					TextColor3 = if diff > 0 then colors.cash else colors.danger,
					Position = UDim2.fromOffset(250, 14),
					Size = UDim2.fromOffset(120, 24),
					Parent = gui,
				})
				TweenService:Create(pop, TweenInfo.new(1.2), { Position = UDim2.fromOffset(250, -10), TextTransparency = 1 }):Play()
				task.delay(1.3, pop.Destroy, pop)
			end
			shownCash = newCash
		end
		cash.Text = UI.formatCash(newCash)
		local lv = player:GetAttribute("Level") or 1
		level.Text = "LV " .. lv
		local xp = player:GetAttribute("XP") or 0
		local toNext = player:GetAttribute("XPToNext") or 100
		setXP(if lv >= 100 then 1 else xp / toNext)
		xpText.Text = if lv >= 100 then "MAX LEVEL" else string.format("%d / %d XP", xp, toNext)
		rank.Text = string.format("%s  ·  %d rep", player:GetAttribute("Rank") or "Nobody", player:GetAttribute("Reputation") or 0)
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
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(260, 22),
		Parent = gui,
	})
	UI.label({ Text = "STAMINA", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = holder })
	local bar, setFill = UI.bar({ Position = UDim2.fromOffset(0, 13), Size = UDim2.new(1, 0, 0, 9), Parent = holder }, colors.stamina)
	local fill = bar:FindFirstChild("Fill") :: Frame
	RunService.RenderStepped:Connect(function()
		local s, maxS, exhausted = Movement.getStamina()
		setFill(s / maxS)
		fill.BackgroundColor3 = if exhausted then colors.danger else colors.stamina
		holder.Visible = s < maxS - 0.5 or Movement.isSprinting()
	end)
end

-- Shows the run timer and highlights the next checkpoint arch.
local function buildRunTracker()
	local panel = UI.new("Frame", {
		Name = "RunTracker",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(220, 54),
		Visible = false,
		Parent = gui,
	}, { UI.corner(12), UI.padding(8) })
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

	RunService.RenderStepped:Connect(function()
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
	UI.label({
		Text = "P Phone   ·   Shift Sprint   ·   C Crouch / Slide   ·   E Interact",
		TextSize = 13,
		TextColor3 = colors.subtext,
		TextStrokeTransparency = 0.6,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -10),
		Size = UDim2.fromOffset(500, 16),
		Parent = gui,
	})
end

function HUD.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	notifySound = UI.new("Sound", { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Parent = SoundService })

	toastHolder = UI.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 76),
		Size = UDim2.fromOffset(320, 300),
		Parent = gui,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	buildStatsCard()
	buildStaminaBar()
	buildRunTracker()
	buildControlsHint()

	remotes:WaitForChild("Notify").OnClientEvent:Connect(function(title: string, body: string)
		if type(title) == "string" and type(body) == "string" then
			HUD.push(title, body)
		end
	end)
end

return HUD
