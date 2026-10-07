-- CITY GRIND: emote wheel (sections 31, 95). Client side.
-- "." (period) / gamepad DPad-Right / on-screen EMOTE button opens a radial wheel
-- with your 8 equipped emotes. Click / tap a slot, press 1-8, or hold "." and
-- release over a slot. Gamepad: point the right stick, press A. EDIT lets you
-- choose which emotes sit in the 8 slots (saved on the server).
-- The server plays every emote so everyone sees it; moving or jumping stops
-- looping emotes. Paired emotes (High Five, Fist Bump, Handshake) ask the
-- nearest player (or the player you opened the wheel on) to accept.
--
-- API: Emotes.play(name, target: Player?) · Emotes.stop() · Emotes.open(target: Player?) · Emotes.close()

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local EmotesConfig = require(shared:WaitForChild("EmotesConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Emotes = {}

local WHEEL_ACTION = "CityEmoteWheel"
local RADIUS = 125
local SLOT_SIZE = 74
local PAIRED_COLOR = Color3.fromRGB(90, 170, 255)

local remotes: Instance? = nil
local EmoteAction: RemoteEvent? = nil
local gui: ScreenGui? = nil
local wheel: Frame
local backdrop: TextButton
local slotButtons: { TextButton } = {}
local centerLabel: TextLabel
local centerSub: TextLabel
local editPanel: Frame
local editSlotButtons: { TextButton } = {}
local editGrid: ScrollingFrame
local pairCard: Frame
local pairText: TextLabel

local isOpen = false
local hovered: number? = nil
local pairTarget: Player? = nil -- set when the wheel was opened from a player's menu
local openedAt = 0
local editSlot = 1
local pairRequestId: string? = nil
local pairToken = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function equipped(): { string }
	local raw = player:GetAttribute("EmoteSlots")
	local list = {}
	if type(raw) == "string" and raw ~= "" then
		for id in raw:gmatch("[^,]+") do
			table.insert(list, id)
		end
	end
	for i = 1, EmotesConfig.SLOTS do
		if not list[i] or not EmotesConfig.BY_ID[list[i]] then
			list[i] = EmotesConfig.DEFAULT_SLOTS[i]
		end
	end
	return list
end

local function myRoot(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function nearestPlayer(): Player?
	local root = myRoot()
	if not root then
		return nil
	end
	local best, bestScore = nil, math.huge
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local character = other.Character
			local r = character and character:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				local offset = r.Position - root.Position
				local dist = offset.Magnitude
				if dist <= EmotesConfig.PAIR_RANGE then
					-- prefer whoever you're facing
					local facing = if dist > 0.1 then root.CFrame.LookVector:Dot(offset.Unit) else 1
					local score = dist - facing * 4
					if score < bestScore then
						best, bestScore = other, score
					end
				end
			end
		end
	end
	return best
end

local function send(...)
	if EmoteAction then
		EmoteAction:FireServer(...)
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Plays an emote by id or name ("Wave", "high five", "Dance"...). Paired emotes
-- need a partner: `target`, or else the nearest player in range.
function Emotes.play(name: string, target: Player?): boolean
	local emote = EmotesConfig.find(name)
	if not emote then
		return false
	end
	if emote.paired then
		local partner = target or nearestPlayer()
		if not partner then
			HUD.push(emote.name:upper(), "Stand next to someone to " .. emote.name:lower() .. ".")
			return false
		end
		send("pairRequest", partner, emote.id)
		return true
	end
	send("play", emote.id)
	return true
end

function Emotes.stop()
	send("stop")
end

---------------------------------------------------------------------------
-- Wheel
---------------------------------------------------------------------------
local function slotAngle(i: number): number
	return math.rad(-90 + (i - 1) * 360 / EmotesConfig.SLOTS)
end

local function refreshWheel()
	local list = equipped()
	for i, button in slotButtons do
		local emote = EmotesConfig.BY_ID[list[i]]
		local icon = button:FindFirstChild("Icon") :: TextLabel
		local label = button:FindFirstChild("Name") :: TextLabel
		local key = button:FindFirstChild("Key") :: TextLabel
		icon.Text = emote.icon
		label.Text = emote.name
		key.Text = tostring(i)
		local stroke = button:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Color = if emote.paired then PAIRED_COLOR else colors.accent
		local selected = hovered == i
		button.BackgroundColor3 = if selected then Color3.fromRGB(60, 60, 78) else colors.panel
		stroke.Transparency = if selected then 0 else 0.6
	end
	local h = hovered and EmotesConfig.BY_ID[list[hovered]]
	if h then
		centerLabel.Text = h.name
		centerSub.Text = if h.paired then (if pairTarget then "with " .. pairTarget.DisplayName else "with nearest player") elseif h.loop then "loops · move to stop" else h.category
	else
		centerLabel.Text = "EMOTES"
		centerSub.Text = if pairTarget then "Paired emotes: " .. pairTarget.DisplayName else (if player:GetAttribute("Emote") ~= "" and player:GetAttribute("Emote") ~= nil then "tap STOP to end" else "pick one")
	end
end

local function setHovered(i: number?)
	if hovered ~= i then
		hovered = i
		refreshWheel()
	end
end

function Emotes.close()
	if not isOpen then
		return
	end
	isOpen = false
	hovered = nil
	wheel.Visible = false
	editPanel.Visible = false
	backdrop.Visible = false
	ContextActionService:UnbindAction("CityEmoteWheelKeys")
end

local function choose(i: number)
	local id = equipped()[i]
	local target = pairTarget
	Emotes.close()
	if id then
		Emotes.play(id, target)
	end
end

function Emotes.open(target: Player?)
	if not gui then
		return
	end
	pairTarget = target
	isOpen = true
	openedAt = os.clock()
	hovered = nil
	editPanel.Visible = false
	wheel.Visible = true
	backdrop.Visible = true
	-- shrink to fit small (phone) screens
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1000, 800)
	local fit = math.clamp((math.min(viewport.X, viewport.Y) - 30) / wheel.Size.X.Offset, 0.5, 1)
	local scale = wheel:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = fit * 0.85
	TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back), { Scale = fit }):Play()
	refreshWheel()
	-- 1-8 pick a slot, A picks the highlighted one, B / Esc closes
	local keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight }
	ContextActionService:BindActionAtPriority("CityEmoteWheelKeys", function(_, state, input)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
		end
		local index = table.find(keys, input.KeyCode)
		if index then
			choose(index)
		elseif input.KeyCode == Enum.KeyCode.ButtonA then
			if hovered then
				choose(hovered)
			end
		else
			Emotes.close()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonB, Enum.KeyCode.Escape, table.unpack(keys))
end

local function toggle()
	if isOpen then
		Emotes.close()
	else
		Emotes.open(nil)
	end
end

local function onWheelKey(_, state: Enum.UserInputState, input: InputObject)
	if state == Enum.UserInputState.Begin then
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		toggle()
	elseif state == Enum.UserInputState.End and isOpen and input.UserInputType == Enum.UserInputType.Keyboard then
		-- hold-and-release: pick whatever the mouse is pointing at
		if os.clock() - openedAt > 0.3 and hovered then
			choose(hovered)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function hoverFromVector(v: Vector2, deadzone: number)
	if v.Magnitude < deadzone then
		return nil
	end
	local angle = math.deg(math.atan2(v.Y, v.X)) + 90 -- 0 = up, clockwise
	local step = 360 / EmotesConfig.SLOTS
	return (math.floor(((angle + step / 2) % 360) / step)) + 1
end

---------------------------------------------------------------------------
-- Edit panel
---------------------------------------------------------------------------
local function refreshEdit()
	local list = equipped()
	for i, button in editSlotButtons do
		local emote = EmotesConfig.BY_ID[list[i]]
		button.Text = emote.icon
		local stroke = button:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Transparency = if i == editSlot then 0 else 0.8
		button.BackgroundColor3 = if i == editSlot then Color3.fromRGB(70, 50, 40) else colors.panelLight
	end
	for _, child in editGrid:GetChildren() do
		if child:IsA("TextButton") then
			local id = child:GetAttribute("EmoteId")
			local slot = table.find(list, id)
			local tagLabel = child:FindFirstChild("Slot") :: TextLabel
			tagLabel.Text = if slot then "#" .. slot else ""
			child.BackgroundColor3 = if slot == editSlot then Color3.fromRGB(70, 50, 40) else colors.panelLight
		end
	end
end

local function openEdit()
	editSlot = hovered or 1
	wheel.Visible = false
	editPanel.Visible = true
	refreshEdit()
end

---------------------------------------------------------------------------
-- Paired request prompt (someone asked you)
---------------------------------------------------------------------------
local function respondPair(accept: boolean)
	if pairRequestId then
		send("pairRespond", pairRequestId, accept)
	end
	pairRequestId = nil
	pairCard.Visible = false
	ContextActionService:UnbindAction("CityEmotePairRespond")
end

local function showPairPrompt(data: any)
	if type(data) ~= "table" or type(data.id) ~= "string" then
		return
	end
	local emote = EmotesConfig.BY_ID[data.emote]
	if not emote then
		return
	end
	pairRequestId = data.id
	pairToken += 1
	local token = pairToken
	pairText.Text = string.format("%s %s wants a %s!", emote.icon, tostring(data.fromName), emote.name:upper())
	pairCard.Visible = true
	-- Enter / gamepad Y accepts (Social uses keyboard Y for its own requests; Backspace stays the gym's)
	ContextActionService:BindActionAtPriority("CityEmotePairRespond", function(_, state, input)
		if state == Enum.UserInputState.Begin then
			respondPair(input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.ButtonY)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Return, Enum.KeyCode.ButtonY)
	task.delay(tonumber(data.seconds) or EmotesConfig.PAIR_REQUEST_SECONDS, function()
		if token == pairToken and pairCard.Visible then
			pairRequestId = nil
			pairCard.Visible = false
			ContextActionService:UnbindAction("CityEmotePairRespond")
		end
	end)
end

---------------------------------------------------------------------------
-- Build UI
---------------------------------------------------------------------------
local function buildUI()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindEmotes",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 8,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Wheel
	local size = (RADIUS + SLOT_SIZE) * 2
	wheel = UI.new("Frame", {
		Name = "Wheel",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		Visible = false,
		Parent = gui,
	}, { UI.new("UIScale", { Scale = 1 }) })
	local ring = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(RADIUS * 2 + SLOT_SIZE + 16, RADIUS * 2 + SLOT_SIZE + 16),
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.45,
		Parent = wheel,
	}, { UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	-- clicking anywhere outside the wheel closes it
	backdrop = UI.new("TextButton", {
		Name = "Backdrop",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.7,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 0,
		Parent = gui,
	})
	backdrop.Activated:Connect(function()
		Emotes.close()
	end)
	ring.Active = true -- clicks on the ring don't close the wheel

	local center = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(150, 150),
		BackgroundColor3 = colors.panel,
		Parent = wheel,
	}, { UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }), UI.stroke(colors.accent, 2, 0.4) })
	centerLabel = UI.label({ Text = "EMOTES", Font = UI.FONT_BLACK, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 20), Parent = center })
	centerSub = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(10, 46), Size = UDim2.new(1, -20, 0, 28), Parent = center })
	local stopButton = UI.button({ Text = "STOP", TextSize = 13, BackgroundColor3 = colors.danger, Position = UDim2.new(0.5, -58, 0, 84), Size = UDim2.fromOffset(54, 28), Parent = center })
	stopButton.Activated:Connect(function()
		Emotes.stop()
		Emotes.close()
	end)
	local editButton = UI.button({ Text = "EDIT", TextSize = 13, Position = UDim2.new(0.5, 4, 0, 84), Size = UDim2.fromOffset(54, 28), Parent = center })
	editButton.Activated:Connect(openEdit)

	for i = 1, EmotesConfig.SLOTS do
		local a = slotAngle(i)
		local button = UI.button({
			Name = "Slot" .. i,
			Text = "",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.cos(a) * RADIUS, 0.5, math.sin(a) * RADIUS),
			Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
			BackgroundColor3 = colors.panel,
			AutoButtonColor = false,
			Parent = wheel,
		}, { UI.stroke(colors.accent, 2, 0.6) })
		UI.corner(SLOT_SIZE // 2).Parent = button
		UI.label({ Name = "Icon", Text = "", TextSize = 28, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 32), Parent = button })
		UI.label({ Name = "Name", Text = "", Font = UI.FONT_BOLD, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(4, 42), Size = UDim2.new(1, -8, 0, 14), Parent = button })
		UI.label({ Name = "Key", Text = "", TextSize = 10, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 56), Size = UDim2.new(1, 0, 0, 12), Parent = button })
		button.MouseEnter:Connect(function()
			setHovered(i)
		end)
		button.Activated:Connect(function()
			choose(i)
		end)
		slotButtons[i] = button
	end

	-- Edit panel
	editPanel = UI.new("Frame", {
		Name = "EditEmotes",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(420, 430),
		BackgroundColor3 = colors.panel,
		Active = true,
		Visible = false,
		Parent = gui,
	}, { UI.corner(16), UI.stroke(colors.accent, 1.5, 0.4), UI.padding(14), UI.new("UISizeConstraint", { MaxSize = Vector2.new(420, 430) }) })
	UI.label({ Text = "EQUIP EMOTES", Font = UI.FONT_BLACK, TextSize = 18, Size = UDim2.new(1, -80, 0, 22), Parent = editPanel })
	UI.label({ Text = "Pick a slot, then an emote.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 16), Parent = editPanel })
	local done = UI.button({ Text = "DONE", TextSize = 13, BackgroundColor3 = colors.accent, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(70, 30), Parent = editPanel })
	done.Activated:Connect(function()
		editPanel.Visible = false
		wheel.Visible = isOpen
		backdrop.Visible = isOpen
		refreshWheel()
	end)
	local slotRow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 44), Parent = editPanel }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i = 1, EmotesConfig.SLOTS do
		local b = UI.button({ Text = "", TextSize = 22, Size = UDim2.fromOffset(42, 42), LayoutOrder = i, Parent = slotRow }, { UI.stroke(colors.accent, 2, 0.8) })
		b.Activated:Connect(function()
			editSlot = i
			refreshEdit()
		end)
		editSlotButtons[i] = b
	end
	editGrid = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 100),
		Size = UDim2.new(1, 0, 1, -100),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = editPanel,
	}, { UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(92, 70), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	for order, emote in EmotesConfig.LIST do
		local b = UI.button({ Text = "", LayoutOrder = order, Parent = editGrid })
		b:SetAttribute("EmoteId", emote.id)
		UI.label({ Text = emote.icon, TextSize = 24, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 30), Parent = b })
		UI.label({ Text = emote.name, Font = UI.FONT_BOLD, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(4, 38), Size = UDim2.new(1, -8, 0, 14), Parent = b })
		UI.label({ Text = if emote.paired then "PAIRED" else emote.category:upper(), TextSize = 9, TextColor3 = if emote.paired then PAIRED_COLOR else colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 53), Size = UDim2.new(1, 0, 0, 12), Parent = b })
		UI.label({ Name = "Slot", Text = "", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.accent, Position = UDim2.fromOffset(6, 4), Size = UDim2.fromOffset(24, 12), Parent = b })
		b.Activated:Connect(function()
			send("equip", editSlot, emote.id)
			editSlot = editSlot % EmotesConfig.SLOTS + 1
		end)
	end

	-- Paired request card
	pairCard = UI.new("Frame", {
		Name = "PairRequest",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -150),
		Size = UDim2.fromOffset(330, 92),
		BackgroundColor3 = colors.panel,
		Visible = false,
		Parent = gui,
	}, { UI.corner(14), UI.stroke(PAIRED_COLOR, 1.5, 0.2), UI.padding(10) })
	pairText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 15, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 34), Parent = pairCard })
	local yes = UI.button({ Text = "ACCEPT", TextSize = 14, BackgroundColor3 = Color3.fromRGB(60, 170, 90), Position = UDim2.new(0, 0, 1, -34), Size = UDim2.new(0.5, -4, 0, 34), Parent = pairCard })
	local no = UI.button({ Text = "NO THANKS", TextSize = 14, Position = UDim2.new(0.5, 4, 1, -34), Size = UDim2.new(0.5, -4, 0, 34), Parent = pairCard })
	yes.Activated:Connect(function()
		respondPair(true)
	end)
	no.Activated:Connect(function()
		respondPair(false)
	end)
	if UserInputService.KeyboardEnabled then
		yes.Text = "ACCEPT (Enter)"
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function hookCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	-- moving or jumping stops a looping emote right away (the server checks too)
	humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		local current = player:GetAttribute("Emote")
		if humanoid.MoveDirection.Magnitude > 0.1 and type(current) == "string" and current ~= "" then
			local emote = EmotesConfig.BY_ID[current]
			if emote and not emote.paired then
				send("stop")
			end
		end
	end)
	humanoid.Jumping:Connect(function(active)
		local current = player:GetAttribute("Emote")
		if active and type(current) == "string" and current ~= "" then
			send("stop")
		end
	end)
end

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
		id = "Emotes",
		label = "EMOTES",
		order = 30,
		run = function(target: Player)
			Emotes.open(target)
		end,
	})
end

function Emotes.start()
	task.spawn(function()
		remotes = shared:WaitForChild("Remotes")
		EmoteAction = (remotes :: Instance):WaitForChild("EmoteAction") :: RemoteEvent
		local EmoteEvent = (remotes :: Instance):WaitForChild("EmoteEvent") :: RemoteEvent
		EmoteEvent.OnClientEvent:Connect(function(kind: any, data: any)
			if kind == "pairPrompt" then
				showPairPrompt(data)
			end
		end)
	end)

	task.spawn(function()
		buildUI()
		player:GetAttributeChangedSignal("EmoteSlots"):Connect(function()
			if isOpen then
				refreshWheel()
			end
			if editPanel.Visible then
				refreshEdit()
			end
		end)

		ContextActionService:BindAction(WHEEL_ACTION, onWheelKey, true, Enum.KeyCode.Period, Enum.KeyCode.DPadRight)
		ContextActionService:SetTitle(WHEEL_ACTION, "Emote")
		ContextActionService:SetPosition(WHEEL_ACTION, UDim2.new(1, -230, 1, -160))

		-- mouse / right-stick highlighting while the wheel is open
		UserInputService.InputChanged:Connect(function(input)
			if not isOpen or not wheel.Visible then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				local c = wheel.AbsolutePosition + wheel.AbsoluteSize / 2
				local scale = (wheel:FindFirstChildOfClass("UIScale") :: UIScale).Scale
				local p = Vector2.new(input.Position.X, input.Position.Y) - c
				if p.Magnitude > 60 * scale and p.Magnitude < (RADIUS + SLOT_SIZE) * scale then
					setHovered(hoverFromVector(p, 60 * scale))
				end
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 or input.KeyCode == Enum.KeyCode.Thumbstick1 then
				local v = Vector2.new(input.Position.X, -input.Position.Y)
				local i = hoverFromVector(v, 0.5)
				if i then
					setHovered(i)
				end
			end
		end)
	end)

	if player.Character then
		task.spawn(hookCharacter, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		Emotes.close()
		hookCharacter(character)
	end)

	task.spawn(addMenuActions)
end

return Emotes
