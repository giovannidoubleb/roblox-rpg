-- CITY GRIND: home UI (spec sections 48, 73, 77, 110).
-- Phone "Home" app, Maple Realty panel, the in-home FURNITURE panel and the
-- placement / edit tools. The client only previews: every purchase and every
-- placement is checked again by the server (src/server/Apartments.luau) using
-- ApartmentsConfig's own tables.
--
-- Controls while placing: mouse moves the ghost, click / PLACE places,
-- R / RB / ROTATE turns 90 degrees, Q / B / CANCEL stops. Touch: tap the floor
-- to move the ghost, then PLACE. Gamepad: aim with the camera, R2 places.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("ApartmentsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Apartments = {}

local GREEN = Color3.fromRGB(90, 220, 120)
local RED = Color3.fromRGB(255, 80, 80)
local HOME_COLOR = Color3.fromRGB(60, 170, 130)

---------------------------------------------------------------------------
-- State from the server
---------------------------------------------------------------------------
type State = {
	ownedTiers: { [string]: boolean },
	activeTier: string,
	inventory: { [string]: number },
	placements: { Cfg.Placement },
	onboarded: boolean,
}
local state: State? = nil
local stateChanged = Instance.new("BindableEvent")

local function setState(newState: any)
	if type(newState) == "table" then
		state = newState
		stateChanged:Fire()
	end
end

local requestRemote: RemoteFunction? = nil
local function getRequest(): RemoteFunction?
	if not requestRemote then
		local remotes = shared:WaitForChild("Remotes", 10)
		requestRemote = remotes and remotes:WaitForChild("ApartmentsRequest", 10) :: RemoteFunction?
	end
	return requestRemote
end

-- Sends a request; shows the server's message as a toast. Returns success.
local busy = false
local function request(action: string, payload: any?): boolean
	if busy then
		return false
	end
	local remote = getRequest()
	if not remote then
		HUD.push("HOME", "Can't reach the city right now.")
		return false
	end
	busy = true
	local ok, success, message, newState = pcall(function()
		return remote:InvokeServer(action, payload)
	end)
	busy = false
	if not ok then
		HUD.push("HOME", "Request failed. Try again.")
		return false
	end
	setState(newState)
	if type(message) == "string" then
		HUD.push(if success then "HOME" else "CAN'T DO THAT", message)
	end
	return success == true
end

local function placedCount(itemId: string): number
	local n = 0
	if state then
		for _, p in state.placements do
			if p.id == itemId then
				n += 1
			end
		end
	end
	return n
end

-- The unit model the local player is standing in, if it is their own.
local function myUnit(): Model?
	if player:GetAttribute("HomeUnit") ~= player.UserId then
		return nil
	end
	local city = Workspace:FindFirstChild("City")
	local folder = city and city:FindFirstChild("Apartments")
	local units = folder and folder:FindFirstChild("Units")
	local unit = units and units:FindFirstChild("Unit_" .. player.UserId)
	return if unit and unit:IsA("Model") then unit else nil
end

local function isGamepad(): boolean
	local last = UserInputService:GetLastInputType()
	return last.Name:sub(1, 7) == "Gamepad"
end

---------------------------------------------------------------------------
-- Shared list builders (phone app + realty panel + furniture panel)
---------------------------------------------------------------------------
local function cardFrame(parent: Instance, height: number, order: number): Frame
	return UI.new("Frame", {
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, -20, 0, height),
		LayoutOrder = order,
		Parent = parent,
	}, { UI.corner(14), UI.padding(10) })
end

local function clearList(container: Instance)
	for _, child in container:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

-- A button that needs a second tap within 4 seconds (for big purchases).
local function confirmButton(props: { [string]: any }, confirmText: string, onConfirm: () -> ())
	local button = UI.button(props)
	local label = button.Text
	local color = button.BackgroundColor3
	local armedAt = 0
	button.Activated:Connect(function()
		if os.clock() - armedAt < 4 then
			armedAt = 0
			button.Text = label
			button.BackgroundColor3 = color
			onConfirm()
			return
		end
		armedAt = os.clock()
		button.Text = confirmText
		button.BackgroundColor3 = colors.accent
		task.delay(4, function()
			if os.clock() - armedAt >= 3.9 and button.Parent then
				button.Text = label
				button.BackgroundColor3 = color
			end
		end)
	end)
	return button
end

local function requirementText(tier: Cfg.Tier): (string, boolean)
	local level = player:GetAttribute("Level") or 1
	local rep = player:GetAttribute("Reputation") or 0
	local parts = {}
	local met = true
	if tier.level > 1 then
		local ok = level >= tier.level
		met = met and ok
		table.insert(parts, "Level " .. tier.level .. (if ok then " ✓" else " ✗"))
	end
	if tier.reputation > 0 then
		local ok = rep >= tier.reputation
		met = met and ok
		table.insert(parts, UI.formatCash(tier.reputation):sub(2) .. " rep" .. (if ok then " ✓" else " ✗"))
	end
	if #parts == 0 then
		return "No requirements", true
	end
	return "Needs " .. table.concat(parts, " · "), met
end

local function tierCard(parent: Instance, tier: Cfg.Tier, order: number)
	local card = cardFrame(parent, 138, order)
	local owned = state ~= nil and state.ownedTiers[tier.id] == true
	local active = state ~= nil and state.activeTier == tier.id
	UI.label({ Text = tier.name, Font = UI.FONT_BLACK, TextSize = 17, Size = UDim2.new(1, -90, 0, 20), Parent = card })
	UI.label({
		Text = if tier.price == 0 then "FREE" else UI.formatCash(tier.price),
		Font = UI.FONT_BLACK,
		TextSize = 15,
		TextColor3 = colors.cash,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 90, 0, 20),
		Parent = card,
	})
	UI.label({
		Text = tier.description,
		TextSize = 12,
		TextColor3 = colors.subtext,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 44),
		Parent = card,
	})
	local reqText, met = requirementText(tier)
	UI.label({
		Text = if owned then string.format("Owned · holds %d pieces", tier.maxItems) else reqText,
		TextSize = 12,
		Font = UI.FONT_BOLD,
		TextColor3 = if owned or met then GREEN else RED,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = card,
	})
	local actionProps = {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(150, 30),
		TextSize = 14,
		Parent = card,
	}
	if active then
		UI.label({ Text = "🏠 You live here", Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = GREEN, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(150, 30), Parent = card })
	elseif owned then
		actionProps.Text = "MOVE IN"
		actionProps.BackgroundColor3 = HOME_COLOR
		UI.button(actionProps).Activated:Connect(function()
			request("MoveIn", tier.id)
		end)
	elseif met then
		actionProps.Text = "BUY " .. UI.formatCash(tier.price)
		actionProps.BackgroundColor3 = colors.xp
		confirmButton(actionProps, "TAP TO CONFIRM", function()
			request("BuyTier", tier.id)
		end)
	else
		UI.label({ Text = "🔒 LOCKED", Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(150, 30), Parent = card })
	end
end

local function storeRow(parent: Instance, item: Cfg.Item, order: number)
	local card = cardFrame(parent, 58, order)
	local owned = if state then state.inventory[item.id] or 0 else 0
	UI.label({ Text = item.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -86, 0, 18), Parent = card })
	UI.label({
		Text = string.format("%s · %s · own %d", UI.formatCash(item.price), item.category, owned),
		TextSize = 12,
		TextColor3 = colors.subtext,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, -86, 0, 16),
		Parent = card,
	})
	if owned >= Cfg.MAX_PER_ITEM then
		UI.label({ Text = "MAX", Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(78, 30), Parent = card })
		return
	end
	local props = { Text = "BUY", TextSize = 14, BackgroundColor3 = colors.xp, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(78, 32), Parent = card }
	local function buy()
		request("BuyFurniture", item.id)
	end
	if item.price >= 1000 then
		confirmButton(props, "SURE?", buy) -- big purchases need a second tap
	else
		UI.button(props).Activated:Connect(buy)
	end
end

---------------------------------------------------------------------------
-- Screen GUI pieces
---------------------------------------------------------------------------
local gui: ScreenGui
local homeButtons: Frame
local furniturePanel: Frame
local furnitureList: ScrollingFrame
local furnitureHeader: TextLabel
local furnitureTab = "items"
local tabButtons: { [string]: TextButton } = {}
local realtyPanel: Frame
local realtyList: ScrollingFrame
local placeBar: Frame
local placeTitle: TextLabel
local placeStatus: TextLabel
local editBar: Frame
local editTitle: TextLabel
local editActions: Frame
local fade: Frame
local fadeText: TextLabel

-- Shrinks a fixed-size panel so it always fits the screen (phones).
local function autoFit(panel: GuiObject, w: number, h: number)
	local scale = UI.new("UIScale", { Parent = panel })
	local function apply()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local vp = camera.ViewportSize
		scale.Scale = math.clamp(math.min((vp.X - 24) / w, (vp.Y - 90) / h), 0.45, 1)
	end
	apply()
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
	end
end

local function panel(name: string, size: Vector2, props: { [string]: any }): Frame
	local defaults = {
		Name = name,
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		Size = UDim2.fromOffset(size.X, size.Y),
		Visible = false,
		Parent = gui,
	}
	for k, v in props do
		defaults[k] = v
	end
	local frame = UI.new("Frame", defaults, { UI.corner(16), UI.stroke(Color3.fromRGB(70, 70, 85), 1.5) })
	autoFit(frame, size.X, size.Y)
	return frame
end

local function scrollList(parent: Instance, top: number): ScrollingFrame
	return UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, top),
		Size = UDim2.new(1, 0, 1, -top - 8),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = parent,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		UI.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8) }),
	})
end

local function closeButton(parent: Instance, onClose: () -> ())
	local b = UI.button({ Text = "✕", TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(34, 34), Parent = parent })
	b.Activated:Connect(onClose)
	return b
end

local function selectFirstButton(container: Instance)
	if not isGamepad() then
		return
	end
	for _, d in container:GetDescendants() do
		if d:IsA("GuiButton") and d.Visible then
			GuiService.SelectedObject = d
			return
		end
	end
end

---------------------------------------------------------------------------
-- Realty panel (opened at the Maple Realty desk)
---------------------------------------------------------------------------
local function renderRealty()
	if not realtyPanel.Visible then
		return
	end
	clearList(realtyList)
	if not state then
		local c = cardFrame(realtyList, 40, 1)
		UI.label({ Text = "Loading listings…", Size = UDim2.fromScale(1, 1), Parent = c })
		return
	end
	for i, tier in Cfg.TIERS do
		tierCard(realtyList, tier, i)
	end
end

local function openRealty()
	realtyPanel.Visible = true
	if not state then
		task.spawn(request, "GetState")
	end
	renderRealty()
	selectFirstButton(realtyPanel)
end

local function buildRealtyPanel()
	realtyPanel = panel("Realty", Vector2.new(460, 540), { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52) })
	UI.label({ Text = "MAPLE REALTY", Font = UI.FONT_BLACK, TextSize = 22, TextColor3 = Color3.fromRGB(120, 230, 170), Position = UDim2.fromOffset(16, 14), Size = UDim2.new(1, -70, 0, 24), Parent = realtyPanel })
	local sub = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.subtext, Position = UDim2.fromOffset(16, 40), Size = UDim2.new(1, -70, 0, 16), Parent = realtyPanel })
	local function refreshSub()
		sub.Text = string.format("Your cash %s · Level %d · %d rep", UI.formatCash(player:GetAttribute("Cash") or 0), player:GetAttribute("Level") or 1, player:GetAttribute("Reputation") or 0)
	end
	for _, attr in { "Cash", "Level", "Reputation" } do
		player:GetAttributeChangedSignal(attr):Connect(function()
			refreshSub()
			renderRealty()
		end)
	end
	refreshSub()
	closeButton(realtyPanel, function()
		realtyPanel.Visible = false
	end)
	realtyList = scrollList(realtyPanel, 66)
end

---------------------------------------------------------------------------
-- Furniture panel (inside your home)
---------------------------------------------------------------------------
local startPlacement: (itemId: string, uid: number?, rot: number?) -> ()
local startEdit: () -> ()

local function renderFurniture()
	if not furniturePanel.Visible then
		return
	end
	for name, b in tabButtons do
		b.BackgroundColor3 = if name == furnitureTab then HOME_COLOR else colors.panelLight
	end
	clearList(furnitureList)
	if not state then
		furnitureHeader.Text = "Loading…"
		return
	end
	local tier = Cfg.TIER_BY_ID[state.activeTier]
	local total = #state.placements
	furnitureHeader.Text = string.format("%s · %d / %d pieces placed", tier.name, total, tier.maxItems)
	if furnitureTab == "store" then
		for i, item in Cfg.ITEMS do
			storeRow(furnitureList, item, i)
		end
		return
	end
	local order = 0
	for _, item in Cfg.ITEMS do
		local owned = state.inventory[item.id] or 0
		if owned > 0 then
			order += 1
			local placed = placedCount(item.id)
			local free = owned - placed
			local card = cardFrame(furnitureList, 58, order)
			UI.label({ Text = item.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -96, 0, 18), Parent = card })
			UI.label({ Text = string.format("%d placed · %d in storage", placed, free), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, -96, 0, 16), Parent = card })
			if free > 0 and total < tier.maxItems then
				local b = UI.button({ Text = "PLACE", TextSize = 14, BackgroundColor3 = HOME_COLOR, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(88, 32), Parent = card })
				b.Activated:Connect(function()
					startPlacement(item.id, nil, 0)
				end)
			else
				UI.label({ Text = if free > 0 then "HOME FULL" else "ALL PLACED", Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(88, 32), Parent = card })
			end
		end
	end
	if order == 0 then
		local c = cardFrame(furnitureList, 52, 1)
		UI.label({ Text = "Nothing in storage. Buy furniture in the STORE tab.", TextSize = 13, TextWrapped = true, Size = UDim2.fromScale(1, 1), Parent = c })
	end
	local hint = cardFrame(furnitureList, 52, order + 1)
	hint.BackgroundTransparency = 1
	UI.label({ Text = "Use EDIT to move, rotate or store pieces you've already placed.", TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, Size = UDim2.fromScale(1, 1), Parent = hint })
end

local function setFurnitureOpen(open: boolean)
	furniturePanel.Visible = open
	if open then
		renderFurniture()
		selectFirstButton(furniturePanel)
	end
end

local function buildFurniturePanel()
	furniturePanel = panel("Furniture", Vector2.new(330, 440), { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 160, 0.5, 0) })
	UI.label({ Text = "FURNITURE", Font = UI.FONT_BLACK, TextSize = 20, TextColor3 = Color3.fromRGB(120, 230, 170), Position = UDim2.fromOffset(14, 12), Size = UDim2.new(1, -60, 0, 22), Parent = furniturePanel })
	furnitureHeader = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(14, 36), Size = UDim2.new(1, -60, 0, 16), Parent = furniturePanel })
	closeButton(furniturePanel, function()
		setFurnitureOpen(false)
	end)
	for i, tab in { { "items", "MY ITEMS" }, { "store", "STORE" } } do
		local b = UI.button({ Text = tab[2], TextSize = 14, Position = UDim2.new((i - 1) * 0.5, if i == 1 then 12 else 4, 0, 60), Size = UDim2.new(0.5, -16, 0, 32), Parent = furniturePanel })
		tabButtons[tab[1]] = b
		b.Activated:Connect(function()
			furnitureTab = tab[1]
			renderFurniture()
		end)
	end
	furnitureList = scrollList(furniturePanel, 100)
end

---------------------------------------------------------------------------
-- Placement mode
---------------------------------------------------------------------------
type Placing = {
	itemId: string,
	item: Cfg.Item,
	uid: number?,
	rot: number,
	x: number,
	z: number,
	f: number,
	valid: boolean,
	reason: string?,
	ghost: Model,
	highlight: Highlight,
	unit: Model,
	tier: Cfg.Tier,
	origin: Vector3,
	floors: RaycastParams,
	original: Model?,
	returnToEdit: boolean,
}
local placing: Placing? = nil
local editing = false
local touchPoint: Vector2? = nil
local renderConn: RBXScriptConnection? = nil
local editHover: Highlight
local editSelect: Highlight
local selectedPiece: Model? = nil

local function pointerRay(): Ray?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local vp = camera.ViewportSize
	if isGamepad() then
		return camera:ViewportPointToRay(vp.X / 2, vp.Y / 2)
	elseif UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
		if touchPoint then
			return camera:ScreenPointToRay(touchPoint.X, touchPoint.Y)
		end
		return camera:ViewportPointToRay(vp.X / 2, vp.Y / 2)
	end
	local mouse = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(mouse.X, mouse.Y)
end

local function floorParams(unit: Model): RaycastParams
	local floors = {}
	for _, d in unit:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Floor" and d:GetAttribute("FloorIndex") then
			table.insert(floors, d)
		end
	end
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = floors
	return params
end

local function setOriginalHidden(model: Model?, hidden: boolean)
	if not model then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if hidden then 0.8 else 0
		end
	end
end

local function makeGhost(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			if d.Name ~= "Hitbox" then
				d.Transparency = math.max(d.Transparency, 0.35)
			end
			if d:IsA("Seat") then
				d.Disabled = true
			end
		elseif d:IsA("Light") then
			d.Enabled = false
		end
	end
end

local function unbindPlacementActions()
	ContextActionService:UnbindAction("HomePlace")
	ContextActionService:UnbindAction("HomeRotate")
	ContextActionService:UnbindAction("HomeCancel")
end

local function stopRender()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
end

local updateEdit: () -> ()
local stopEdit: () -> ()

local function cancelPlacement(silent: boolean?)
	local p = placing
	if not p then
		return
	end
	placing = nil
	p.ghost:Destroy()
	p.highlight:Destroy()
	setOriginalHidden(p.original, false)
	placeBar.Visible = false
	unbindPlacementActions()
	stopRender()
	if p.returnToEdit and not silent and myUnit() then
		startEdit()
	end
end

local function updateGhost()
	local p = placing
	if not p then
		return
	end
	if not p.unit.Parent or myUnit() ~= p.unit then
		cancelPlacement(true)
		return
	end
	local ray = pointerRay()
	local result = ray and Workspace:Raycast(ray.Origin, ray.Direction * 500, p.floors)
	if result then
		local rel = result.Position - p.origin
		p.x = math.round(rel.X)
		p.z = math.round(rel.Z)
		p.f = result.Instance:GetAttribute("FloorIndex") or 1
		local ok, reason = Cfg.validatePlacement(p.tier.id, p.itemId, p.x, p.z, p.f, p.rot, if state then state.placements else {}, p.uid)
		p.valid = ok
		p.reason = reason
		p.ghost:PivotTo(Cfg.pieceCFrame(p.origin, p.tier, p.item, p.x, p.z, p.f, p.rot))
	else
		p.valid = false
		p.reason = "Point at the floor of your home."
	end
	local color = if p.valid then GREEN else RED
	p.highlight.FillColor = color
	p.highlight.OutlineColor = color
	placeStatus.Text = if p.valid then "Looks good — PLACE it" else (p.reason or "Can't go here")
	placeStatus.TextColor3 = color
end

local function rotatePlacement()
	local p = placing
	if p then
		p.rot = (p.rot + 90) % 360
		updateGhost()
	end
end

local function confirmPlacement()
	local p = placing
	if not p then
		return
	end
	updateGhost()
	if not p.valid then
		HUD.push("CAN'T PLACE HERE", p.reason or "Try another spot.")
		return
	end
	local payload = { id = p.itemId, u = p.uid, x = p.x, z = p.z, f = p.f, r = p.rot }
	local ok = request(if p.uid then "Move" else "Place", payload)
	if ok and placing == p then
		cancelPlacement()
	end
end

startPlacement = function(itemId: string, uid: number?, rot: number?)
	local unit = myUnit()
	local item = Cfg.ITEM_BY_ID[itemId]
	if not unit or not item then
		HUD.push("HOME", "Go inside your home to place furniture.")
		return
	end
	local tier = Cfg.TIER_BY_ID[unit:GetAttribute("Tier") or ""]
	local origin = unit:GetAttribute("Origin")
	if not tier or typeof(origin) ~= "Vector3" then
		return
	end
	cancelPlacement(true)
	local returnToEdit = editing
	if editing then
		stopEdit()
	end
	setFurnitureOpen(false)

	local ghost = Cfg.buildItem(itemId) :: Model
	makeGhost(ghost)
	ghost.Parent = Workspace.CurrentCamera
	local highlight = UI.new("Highlight", {
		Adornee = ghost,
		FillTransparency = 0.55,
		OutlineTransparency = 0,
		DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
		Parent = ghost,
	})
	local original: Model? = nil
	if uid then
		local furniture = unit:FindFirstChild("Furniture")
		if furniture then
			for _, m in furniture:GetChildren() do
				if m:GetAttribute("PlacementId") == uid and m:IsA("Model") then
					original = m
				end
			end
		end
		setOriginalHidden(original, true)
	end
	placing = {
		itemId = itemId,
		item = item,
		uid = uid,
		rot = rot or 0,
		x = 0,
		z = 0,
		f = 1,
		valid = false,
		reason = nil,
		ghost = ghost,
		highlight = highlight,
		unit = unit,
		tier = tier,
		origin = origin,
		floors = floorParams(unit),
		original = original,
		returnToEdit = returnToEdit,
	}
	placeTitle.Text = (if uid then "MOVING  " else "PLACING  ") .. item.name:upper()
	placeBar.Visible = true

	ContextActionService:BindAction("HomePlace", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			task.spawn(confirmPlacement) -- it invokes the server; never yield inside a CAS callback
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Return, Enum.KeyCode.ButtonR2)
	ContextActionService:BindAction("HomeRotate", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			rotatePlacement()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonR1)
	ContextActionService:BindAction("HomeCancel", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			cancelPlacement()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)

	stopRender()
	renderConn = RunService.RenderStepped:Connect(updateGhost)
	updateGhost()
end

---------------------------------------------------------------------------
-- Edit mode: pick a placed piece, then MOVE / ROTATE / STORE it
---------------------------------------------------------------------------
local function pieceAt(screenRay: Ray?): Model?
	local unit = myUnit()
	local furniture = unit and unit:FindFirstChild("Furniture")
	if not furniture or not screenRay then
		return nil
	end
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { furniture }
	local result = Workspace:Raycast(screenRay.Origin, screenRay.Direction * 500, params)
	local inst: Instance? = result and result.Instance
	while inst and inst.Parent ~= furniture do
		inst = inst.Parent
	end
	return if inst and inst:IsA("Model") then inst else nil
end

local function placementOf(model: Model): Cfg.Placement?
	local uid = model:GetAttribute("PlacementId")
	if state then
		for _, p in state.placements do
			if p.u == uid then
				return p
			end
		end
	end
	return nil
end

local function selectPiece(model: Model?)
	selectedPiece = model
	editSelect.Adornee = model
	editActions.Visible = model ~= nil
	if model then
		local item = Cfg.ITEM_BY_ID[model:GetAttribute("ItemId") or ""]
		editTitle.Text = "SELECTED  " .. (if item then item.name:upper() else "PIECE")
		selectFirstButton(editActions)
	else
		editTitle.Text = if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then "Tap a piece to select it" else "Click a piece to select it (R2 on gamepad)"
	end
end

updateEdit = function()
	if not editing then
		return
	end
	if not myUnit() then
		stopEdit()
		return
	end
	if selectedPiece and not selectedPiece.Parent then
		selectPiece(nil)
	end
	local hover = pieceAt(pointerRay())
	editHover.Adornee = if hover ~= selectedPiece then hover else nil
end

local function editSelectAtPointer(screenRay: Ray?)
	local piece = pieceAt(screenRay)
	if piece then
		selectPiece(piece)
	end
end

stopEdit = function()
	if not editing then
		return
	end
	editing = false
	editBar.Visible = false
	editHover.Adornee = nil
	selectPiece(nil)
	ContextActionService:UnbindAction("HomeEditSelect")
	ContextActionService:UnbindAction("HomeEditDone")
	stopRender()
end

startEdit = function()
	if not myUnit() then
		return
	end
	cancelPlacement(true)
	setFurnitureOpen(false)
	editing = true
	editBar.Visible = true
	selectPiece(nil)
	ContextActionService:BindAction("HomeEditSelect", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			editSelectAtPointer(pointerRay())
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Return, Enum.KeyCode.ButtonR2)
	ContextActionService:BindAction("HomeEditDone", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			stopEdit()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)
	stopRender()
	renderConn = RunService.RenderStepped:Connect(updateEdit)
end

local function buildBars()
	placeBar = panel("PlaceBar", Vector2.new(440, 112), { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -50) })
	placeTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 18), Parent = placeBar })
	placeStatus = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 16), Parent = placeBar })
	local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 52), Size = UDim2.new(1, -24, 0, 40), Parent = placeBar }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	})
	local function barButton(parent: Instance, text: string, color: Color3, fn: () -> ()): TextButton
		local b = UI.button({ Text = text, TextSize = 15, BackgroundColor3 = color, Size = UDim2.fromOffset(128, 40), Parent = parent })
		b.Activated:Connect(fn)
		return b
	end
	barButton(row, "⟳ ROTATE", colors.panelLight, rotatePlacement)
	barButton(row, "✔ PLACE", HOME_COLOR, confirmPlacement)
	barButton(row, "✕ CANCEL", Color3.fromRGB(140, 50, 50), function()
		cancelPlacement()
	end)
	if UserInputService.KeyboardEnabled then
		UI.label({ Text = "Click to place · R rotate · Q cancel", TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -2), Size = UDim2.new(1, 0, 0, 14), Parent = placeBar })
	end

	editBar = panel("EditBar", Vector2.new(560, 104), { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -50) })
	editTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 18), Parent = editBar })
	local editRow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 44), Size = UDim2.new(1, -24, 0, 40), Parent = editBar }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	editActions = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(400, 40), LayoutOrder = 1, Visible = false, Parent = editRow }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	barButton(editActions, "✥ MOVE", HOME_COLOR, function()
		local piece = selectedPiece
		local p = piece and placementOf(piece)
		if p then
			startPlacement(p.id, p.u, p.r)
		end
	end)
	barButton(editActions, "⟳ ROTATE", colors.panelLight, function()
		local piece = selectedPiece
		local p = piece and placementOf(piece)
		if p then
			request("Move", { u = p.u, x = p.x, z = p.z, f = p.f, r = (p.r + 90) % 360 })
		end
	end)
	barButton(editActions, "📦 STORE", Color3.fromRGB(150, 110, 40), function()
		local piece = selectedPiece
		local p = piece and placementOf(piece)
		if p and request("Store", p.u) then
			selectPiece(nil)
		end
	end)
	local done = barButton(editRow, "DONE", Color3.fromRGB(70, 70, 85), function()
		stopEdit()
	end)
	done.LayoutOrder = 2
	done.Size = UDim2.fromOffset(100, 40)

	editHover = UI.new("Highlight", { FillTransparency = 1, OutlineColor = Color3.new(1, 1, 1), OutlineTransparency = 0.2, DepthMode = Enum.HighlightDepthMode.Occluded, Parent = Workspace.CurrentCamera })
	editSelect = UI.new("Highlight", { FillColor = HOME_COLOR, FillTransparency = 0.6, OutlineColor = GREEN, OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Parent = Workspace.CurrentCamera })
end

---------------------------------------------------------------------------
-- Home buttons, welcome card, sleep fade
---------------------------------------------------------------------------
local function buildHomeButtons()
	homeButtons = UI.new("Frame", {
		Name = "HomeButtons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, -60),
		Size = UDim2.fromOffset(140, 136),
		Visible = false,
		Parent = gui,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local furniture = UI.button({ Text = "🛋 FURNITURE", TextSize = 14, BackgroundColor3 = HOME_COLOR, Size = UDim2.fromOffset(140, 40), LayoutOrder = 1, Parent = homeButtons })
	furniture.Activated:Connect(function()
		if placing then
			cancelPlacement(true)
		end
		if editing then
			stopEdit()
		end
		setFurnitureOpen(not furniturePanel.Visible)
	end)
	local edit = UI.button({ Text = "✏ EDIT", TextSize = 14, BackgroundColor3 = colors.panelLight, Size = UDim2.fromOffset(140, 40), LayoutOrder = 2, Parent = homeButtons })
	edit.Activated:Connect(function()
		if editing then
			stopEdit()
		else
			startEdit()
		end
	end)
	local hint = UI.label({ Text = "", TextSize = 11, TextColor3 = colors.subtext, TextStrokeTransparency = 0.6, TextWrapped = true, Size = UDim2.fromOffset(140, 32), LayoutOrder = 3, Parent = homeButtons })
	if UserInputService.KeyboardEnabled then
		hint.Text = "B furniture · G edit"
	elseif UserInputService.GamepadEnabled then
		hint.Text = "D-pad ← furniture · → edit"
	end
end

local function showWelcome(tierName: string)
	local card = panel("Welcome", Vector2.new(420, 300), { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Visible = true })
	UI.label({ Text = "WELCOME HOME", Font = UI.FONT_BLACK, TextSize = 24, TextColor3 = Color3.fromRGB(120, 230, 170), TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 28), Parent = card })
	UI.label({
		Text = "This " .. tierName .. " at Maple Court is yours.\n\n"
			.. "• Sleep in your bed to fully restore stamina.\n"
			.. "• FURNITURE: place what you own or buy more in the Store.\n"
			.. "• EDIT: move, rotate or store placed pieces.\n"
			.. "• Bigger homes: Maple Realty outside, or the Home app on your phone.",
		TextSize = 14,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(20, 54),
		Size = UDim2.new(1, -40, 0, 180),
		Parent = card,
	})
	local ok = UI.button({ Text = "GOT IT", TextSize = 16, BackgroundColor3 = HOME_COLOR, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.fromOffset(160, 40), Parent = card })
	ok.Activated:Connect(function()
		card:Destroy()
	end)
	selectFirstButton(card)
end

local function sleepFade()
	fade.Visible = true
	fade.BackgroundTransparency = 1
	fadeText.TextTransparency = 1
	TweenService:Create(fade, TweenInfo.new(0.6), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(fadeText, TweenInfo.new(0.6), { TextTransparency = 0 }):Play()
	task.delay(1.9, function()
		TweenService:Create(fade, TweenInfo.new(0.8), { BackgroundTransparency = 1 }):Play()
		local t = TweenService:Create(fadeText, TweenInfo.new(0.8), { TextTransparency = 1 })
		t:Play()
		t.Completed:Wait()
		fade.Visible = false
	end)
end

---------------------------------------------------------------------------
-- TV channels (screens are tagged by the server; this only changes the picture)
---------------------------------------------------------------------------
local CHANNELS = {
	{ ch = "CG1", show = "Neighborhood Hoops · LIVE", color = Color3.fromRGB(20, 30, 80) },
	{ ch = "CG2", show = "City News: Maple Court rents rising", color = Color3.fromRGB(120, 20, 30) },
	{ ch = "CG3", show = "Grind FM · Late Night Beats", color = Color3.fromRGB(70, 20, 110) },
	{ ch = "CG4", show = "Mama's Kitchen: Sunday Gravy", color = Color3.fromRGB(130, 70, 20) },
	{ ch = "CG5", show = "Weather: clear skies tonight", color = Color3.fromRGB(20, 100, 140) },
	{ ch = "CG6", show = "Iron Box Workout Hour", color = Color3.fromRGB(30, 100, 50) },
}
local function runTVs()
	local index = 1
	while true do
		task.wait(5)
		index = index % #CHANNELS + 1
		local channel = CHANNELS[index]
		for _, screen in CollectionService:GetTagged("CityGrindTV") do
			local tvGui = screen:FindFirstChild("TVGui")
			local bg = tvGui and tvGui:FindFirstChild("BG")
			if bg and bg:IsA("Frame") then
				bg.BackgroundColor3 = channel.color
				local show = bg:FindFirstChild("Show")
				local ch = bg:FindFirstChild("Channel")
				if show and show:IsA("TextLabel") then
					show.Text = channel.show
				end
				if ch and ch:IsA("TextLabel") then
					ch.Text = channel.ch
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Phone app
---------------------------------------------------------------------------
local phoneTab = "homes"

local function buildPhoneApp(content: ScrollingFrame)
	local function render()
		Phone.clear(content)
		local top = Phone.card(content, 122, 0)
		local tierName = if state then Cfg.TIER_BY_ID[state.activeTier].name else "…"
		UI.label({ Text = "Your home", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = top })
		UI.label({ Text = tierName .. " · Maple Court", Font = UI.FONT_BLACK, TextSize = 16, Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 20), Parent = top })
		if (player:GetAttribute("HomeUnit") or 0) == player.UserId then
			UI.label({ Text = "🏠 You're home", Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = GREEN, Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 0, 24), Parent = top })
		else
			local gps = UI.button({ Text = "📍 GO HOME (GPS)", TextSize = 13, BackgroundColor3 = colors.xp, Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 0, 28), Parent = top })
			gps.Activated:Connect(function()
				Phone.setGPS("Maple Court", Cfg.HOME_GPS)
			end)
		end
		for i, tab in { { "homes", "HOMES" }, { "store", "FURNITURE" } } do
			local b = UI.button({
				Text = tab[2],
				TextSize = 12,
				BackgroundColor3 = if phoneTab == tab[1] then HOME_COLOR else Color3.fromRGB(55, 55, 68),
				Position = UDim2.new((i - 1) * 0.5, if i == 1 then 0 else 3, 0, 72),
				Size = UDim2.new(0.5, -3, 0, 24),
				Parent = top,
			})
			b.Activated:Connect(function()
				phoneTab = tab[1]
				render()
			end)
		end
		if not state then
			local c = Phone.card(content, 40, 1)
			UI.label({ Text = "Loading…", Size = UDim2.fromScale(1, 1), Parent = c })
			return
		end
		if phoneTab == "homes" then
			for i, tier in Cfg.TIERS do
				tierCard(content, tier, i)
			end
		else
			local note = Phone.card(content, 40, 1)
			UI.label({ Text = "Delivered to your storage. Place it with FURNITURE at home.", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, Size = UDim2.fromScale(1, 1), Parent = note })
			for i, item in Cfg.ITEMS do
				storeRow(content, item, i + 1)
			end
		end
	end

	local function refreshIfOpen()
		Phone.refresh("Homes")
	end
	stateChanged.Event:Connect(refreshIfOpen)
	for _, attr in { "Level", "Reputation", "HomeUnit" } do
		player:GetAttributeChangedSignal(attr):Connect(refreshIfOpen)
	end

	return function()
		render()
		if not state then
			if request("GetState") then
				render()
			end
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function onHomeUnitChanged()
	local home = myUnit() ~= nil or player:GetAttribute("HomeUnit") == player.UserId
	homeButtons.Visible = home
	if home then
		ContextActionService:BindAction("HomeFurniture", function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				if placing then
					cancelPlacement(true)
				end
				if editing then
					stopEdit()
				end
				setFurnitureOpen(not furniturePanel.Visible)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.B, Enum.KeyCode.DPadLeft)
		ContextActionService:BindAction("HomeEdit", function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				if editing then
					stopEdit()
				else
					startEdit()
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.G, Enum.KeyCode.DPadRight)
	else
		ContextActionService:UnbindAction("HomeFurniture")
		ContextActionService:UnbindAction("HomeEdit")
		cancelPlacement(true)
		stopEdit()
		setFurnitureOpen(false)
	end
end

local function setup()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindHome",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 4,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildHomeButtons()
	buildFurniturePanel()
	buildRealtyPanel()
	buildBars()
	fade = UI.new("Frame", { Name = "SleepFade", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(0, -60), Visible = false, ZIndex = 50, Parent = gui })
	fade.Size = UDim2.new(1, 0, 1, 60)
	fadeText = UI.label({ Text = "Zzz… resting", Font = UI.FONT_BLACK, TextSize = 28, TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 51, Parent = fade })

	stateChanged.Event:Connect(function()
		renderFurniture()
		renderRealty()
		-- a rebuilt unit or a tier change invalidates whatever was being placed
		local p = placing
		if p and (not state or state.activeTier ~= p.tier.id) then
			cancelPlacement(true)
		end
		if selectedPiece and not placementOf(selectedPiece) then
			selectPiece(nil)
		end
	end)
	player:GetAttributeChangedSignal("HomeUnit"):Connect(onHomeUnitChanged)
	player:GetAttributeChangedSignal("Cash"):Connect(renderFurniture)
	onHomeUnitChanged()

	-- clicks / taps in the world
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if placing then
			confirmPlacement()
		elseif editing then
			editSelectAtPointer(pointerRay())
		end
	end)
	UserInputService.TouchTapInWorld:Connect(function(position, processed)
		if processed then
			return
		end
		touchPoint = position
		if placing then
			updateGhost()
		elseif editing then
			local camera = Workspace.CurrentCamera
			if camera then
				editSelectAtPointer(camera:ScreenPointToRay(position.X, position.Y))
			end
		end
	end)

	local remotes = shared:WaitForChild("Remotes")
	local event = remotes:WaitForChild("ApartmentsEvent") :: RemoteEvent
	event.OnClientEvent:Connect(function(kind: any, arg: any)
		if kind == "State" then
			setState(arg)
		elseif kind == "OpenRealty" then
			openRealty()
		elseif kind == "Sleep" then
			sleepFade()
		elseif kind == "Welcome" then
			showWelcome(if type(arg) == "string" then arg else "home")
		end
	end)

	if not player:GetAttribute("DataLoaded") then
		player:GetAttributeChangedSignal("DataLoaded"):Wait()
	end
	if not state then
		request("GetState")
	end
end

function Apartments.start()
	Phone.addApp({ id = "Homes", label = "Home", icon = "🏠", color = HOME_COLOR }, buildPhoneApp)
	task.spawn(setup)
	task.spawn(runTVs)
end

return Apartments
