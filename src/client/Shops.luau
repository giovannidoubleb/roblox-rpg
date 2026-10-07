-- CITY GRIND: shop panels, try-on preview, mirror camera, Closet phone app
-- and buff chips (sections 49, 74-77, 110).
--
-- The server opens a panel (ShopOpen) when you use a rack, chair or counter.
-- Try-ons are applied only on your own screen with the same ShopsConfig.Look
-- builder the server uses; nothing is worn for real until the server applies it.
-- Every button sends one ShopAction to the server, which re-checks everything.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local ShopsConfig = require(shared:WaitForChild("ShopsConfig"))
local remotes = shared:WaitForChild("Remotes")

local Look = ShopsConfig.Look
local ITEMS = ShopsConfig.ITEMS
local player = Players.LocalPlayer
local colors = UI.colors

local Shops = {}

local PANEL_W, PANEL_H = 380, 560
local BLUE = Color3.fromRGB(70, 140, 255)
local GREEN = Color3.fromRGB(60, 190, 100)

local ShopGetState: RemoteFunction? = nil
local ShopAction: RemoteFunction? = nil

local state: any = nil -- last snapshot from the server

---------------------------------------------------------------------------
-- Server calls
---------------------------------------------------------------------------
local function fetchState(): any
	if not ShopGetState then
		return state
	end
	local ok, result = pcall(function()
		return (ShopGetState :: RemoteFunction):InvokeServer()
	end)
	if ok and type(result) == "table" then
		state = result
	end
	return state
end

local setStatus: (string, boolean) -> () = function() end

local function act(action: string, ...: any): boolean
	if not ShopAction then
		setStatus("Still connecting...", false)
		return false
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return (ShopAction :: RemoteFunction):InvokeServer(action, table.unpack(args, 1, args.n))
	end)
	if not ok or type(result) ~= "table" then
		setStatus("Couldn't reach the shop. Try again.", false)
		return false
	end
	if type(result.state) == "table" then
		state = result.state
	end
	if type(result.msg) == "string" then
		setStatus(result.msg, result.ok == true)
	end
	return result.ok == true
end

local function owns(id: string): boolean
	return state ~= nil and table.find(state.owned, id) ~= nil
end

local function wearing(item: ShopsConfig.Item, variant: number?): boolean
	if not state or state.useRobloxAvatar or state.equipped[item.slot] ~= item.id then
		return false
	end
	return variant == nil or state.colours[item.slot] == variant
end

local function currentLook(): ShopsConfig.LookData
	return {
		equipped = table.clone(state.equipped),
		colours = table.clone(state.colours),
		hair = state.hair,
		hairColor = state.hairColor,
		facial = state.facial,
	}
end

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function inVehicle(): boolean
	local h = humanoid()
	local seat = h and h.SeatPart
	return seat ~= nil and not seat:GetAttribute("BarberChair") and not seat:GetAttribute("KitchenSeat")
end

---------------------------------------------------------------------------
-- Local try-on preview
---------------------------------------------------------------------------
type Saved = { v: any }
local recorded: { [Instance]: { [string]: Saved } } = {}
local previewFolder: Folder? = nil
local previewing = false

local function record(inst: Instance, prop: string)
	local props = recorded[inst]
	if not props then
		props = {}
		recorded[inst] = props
	end
	if props[prop] == nil then
		props[prop] = { v = (inst :: any)[prop] }
	end
end

local function setLocal(inst: Instance, prop: string, value: any)
	record(inst, prop);
	(inst :: any)[prop] = value
end

-- Hides a server-built piece (or an avatar accessory) on this screen only.
local function hideTree(root: Instance)
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, d in list do
		if d:IsA("BasePart") then
			setLocal(d, "Transparency", 1)
		elseif d:IsA("SurfaceGui") or d:IsA("WrapLayer") then
			setLocal(d, "Enabled", false)
		end
	end
end

-- Shows an avatar accessory the server hid for the current look.
local function showHidden(accessory: Accessory)
	for _, d in accessory:GetDescendants() do
		local original = d:GetAttribute("CGOrigT")
		if d:IsA("BasePart") and type(original) == "number" then
			setLocal(d, "Transparency", original)
		end
	end
end

local function endPreview()
	if previewFolder then
		previewFolder:Destroy()
		previewFolder = nil
	end
	for inst, props in recorded do
		if inst.Parent then
			for prop, saved in props do
				if prop == "Color" and inst:GetAttribute("CGColor") ~= nil then
					(inst :: BasePart).Color = inst:GetAttribute("CGColor")
				elseif prop == "Material" and type(inst:GetAttribute("CGMat")) == "string" then
					local name = inst:GetAttribute("CGMat")
					pcall(function()
						(inst :: BasePart).Material = (Enum.Material :: any)[name]
					end)
				else
					pcall(function()
						(inst :: any)[prop] = saved.v
					end)
				end
			end
		end
	end
	table.clear(recorded)
	previewing = false
end

local function startPreview(look: ShopsConfig.LookData)
	endPreview()
	local character = player.Character
	if not character or not humanoid() then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "CityGrindPreview"
	folder.Parent = character
	previewFolder = folder
	previewing = true
	local ok, err = pcall(Look.build, character, look, {
		isServer = false,
		folder = folder,
		playerName = player.DisplayName,
		strip = function(char: Model)
			for _, child in char:GetChildren() do
				if child:IsA("Shirt") then
					setLocal(child, "ShirtTemplate", "")
				elseif child:IsA("Pants") then
					setLocal(child, "PantsTemplate", "")
				elseif child:IsA("ShirtGraphic") then
					setLocal(child, "Graphic", "")
				elseif child:IsA("Folder") and child.Name == "CityGrindLook" then
					hideTree(child)
				elseif child:IsA("Accessory") then
					if child:GetAttribute("CityGrind") or Look.isLayeredClothing(child) then
						hideTree(child)
					elseif child:GetAttribute("CGHidden") then
						showHidden(child)
					end
				end
			end
		end,
		hide = function(accessory: Accessory)
			hideTree(accessory)
		end,
		setColor = function(part: BasePart, color: Color3, mat: Enum.Material)
			setLocal(part, "Color", color)
			setLocal(part, "Material", mat)
		end,
	})
	if not ok then
		warn("[CityGrind] Shops preview failed:", err)
	end
end

---------------------------------------------------------------------------
-- Mirror camera (Roblox mirrors can't reflect players, so face the camera at you)
---------------------------------------------------------------------------
local mirrorOn = false
local mirrorYaw = 0
local mirrorHead = false
local mirrorBar: Frame
local mirrorLabel: TextButton

local function mirrorStep()
	local camera = Workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local head = character and character:FindFirstChild("Head")
	if not camera or not root or not root:IsA("BasePart") or not head or not head:IsA("BasePart") then
		return
	end
	local flat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	local dir = CFrame.Angles(0, mirrorYaw, 0):VectorToWorldSpace(flat.Unit)
	local focus = if mirrorHead then head.Position else root.Position + Vector3.new(0, 0.5, 0)
	local dist = if mirrorHead then 4.6 else 9.5
	local eye = focus + dir * dist + Vector3.new(0, if mirrorHead then 0.4 else 1.4, 0)
	-- slide the camera left so you stand to the right of the shop panel
	local target = CFrame.lookAt(eye, focus) * CFrame.new(-dist * 0.3, 0, 0)
	camera.CFrame = camera.CFrame:Lerp(target, 0.2)
end

local function setMirror(on: boolean, head: boolean?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	mirrorHead = head == true
	if mirrorLabel then
		mirrorLabel.Text = if mirrorHead then "CLOSE-UP" else "FULL BODY"
	end
	if on == mirrorOn then
		return
	end
	mirrorOn = on
	if mirrorBar then
		mirrorBar.Visible = on
	end
	if on then
		mirrorYaw = 0
		camera.CameraType = Enum.CameraType.Scriptable
		RunService:BindToRenderStep("CityGrindMirror", Enum.RenderPriority.Camera.Value + 1, mirrorStep)
		ContextActionService:BindAction("CityGrindMirrorTurn", function(_, inputState, input)
			if inputState == Enum.UserInputState.Begin then
				local left = input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.ButtonL1
				mirrorYaw += if left then -math.rad(30) else math.rad(30)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
	else
		RunService:UnbindFromRenderStep("CityGrindMirror")
		ContextActionService:UnbindAction("CityGrindMirrorTurn")
		camera.CameraType = Enum.CameraType.Custom
		local h = humanoid()
		if h then
			camera.CameraSubject = h
		end
	end
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
local gui: ScreenGui
local panel: Frame
local panelScale: UIScale
local titleLabel: TextLabel
local subtitleLabel: TextLabel
local body: Frame
local statusLabel: TextLabel
local mode: string? = nil
local modeOpts: any = {}
local renderers: { [string]: (Frame, any) -> () } = {}
local scrollMemory: { [string]: Vector2 } = {}

local TITLES = {
	Threads = { "THREADS", "Clothing · Try on, buy, equip" },
	Closet = { "CLOSET", "Your clothes and saved outfits" },
	Barber = { "FRESH CUTS", "Pick a style · preview · pay" },
	Mart = { "CORNER MART", "Drinks and snacks" },
	Kitchen = { "MAMA'S KITCHEN", "Order at the counter, eat at a table" },
}

setStatus = function(text: string, good: boolean)
	if statusLabel then
		statusLabel.Text = text
		statusLabel.TextColor3 = if good then colors.cash else colors.danger
	end
end

local function render()
	if not mode or not body then
		return
	end
	for _, child in body:GetChildren() do
		child:Destroy()
	end
	local renderer = renderers[mode]
	if renderer then
		renderer(body, modeOpts)
	end
end

local function closePanel()
	if not mode then
		return
	end
	mode = nil
	panel.Visible = false
	endPreview()
	setMirror(false)
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = nil
	end
	ContextActionService:UnbindAction("CityGrindShopClose")
end

local function openPanel(newMode: string, opts: any?)
	if not TITLES[newMode] or not panel then
		return
	end
	if Phone.isOpen() then
		Phone.setOpen(false)
	end
	endPreview()
	mode = newMode
	modeOpts = opts or {}
	titleLabel.Text = TITLES[newMode][1]
	subtitleLabel.Text = TITLES[newMode][2]
	setStatus("", true)
	panel.Visible = true
	if not fetchState() then
		setStatus("Your data is still loading.", false)
	end
	render()
	local wantsMirror = newMode == "Threads" or newMode == "Closet" or newMode == "Barber"
	setMirror(wantsMirror, newMode == "Barber")
	ContextActionService:BindAction("CityGrindShopClose", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			closePanel()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.ButtonB)
	if UserInputService.GamepadEnabled then
		local first = body:FindFirstChildWhichIsA("GuiButton", true)
		GuiService.SelectedObject = first
	end
end

---------------------------------------------------------------------------
-- Small widgets
---------------------------------------------------------------------------
local function hscroll(parent: Instance, y: number, height: number): ScrollingFrame
	return UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, height),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		Parent = parent,
	}, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

local function chip(parent: Instance, text: string, selected: boolean, accent: Color3, order: number, onClick: () -> ()): TextButton
	local b = UI.button({
		Text = text,
		TextSize = 13,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = if selected then accent else colors.panelLight,
		TextColor3 = if selected then Color3.new(0, 0, 0) else colors.text,
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }),
	})
	b.Activated:Connect(onClick)
	return b
end

local function swatch(parent: Instance, c1: Color3, c2: Color3, size: number, selected: boolean, onClick: (() -> ())?): GuiObject
	local s = UI.new(if onClick then "TextButton" else "Frame", {
		BackgroundColor3 = c1,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	}, {
		UI.corner(size // 2),
		UI.stroke(if selected then Color3.new(1, 1, 1) else Color3.fromRGB(80, 80, 90), if selected then 2.5 else 1),
		UI.new("Frame", {
			BackgroundColor3 = c2,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromOffset(size // 3, size // 3),
		}, { UI.corner(size // 6), UI.stroke(Color3.fromRGB(20, 20, 24), 1) }),
	})
	if onClick then
		(s :: TextButton).Text = ""
		;(s :: TextButton).Activated:Connect(onClick)
	end
	return s
end

local function actionButton(parent: Instance, text: string, color: Color3, pos: UDim2, size: UDim2, onClick: () -> ()): TextButton
	local b = UI.button({
		Text = text,
		TextSize = 14,
		BackgroundColor3 = color,
		TextColor3 = if color == colors.panelLight then colors.text else Color3.new(1, 1, 1),
		Position = pos,
		Size = size,
		Parent = parent,
	})
	b.Activated:Connect(onClick)
	return b
end

local function vlist(parent: Instance, y: number): ScrollingFrame
	return UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 1, -y),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		Parent = parent,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		UI.new("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }),
	})
end

local function sectionTitle(parent: Instance, text: string, order: number)
	UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = order, Parent = parent })
end

local function card(parent: Instance, height: number, order: number): Frame
	return UI.new("Frame", { BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, 0, 0, height), LayoutOrder = order, Parent = parent }, { UI.corner(12), UI.padding(10) })
end

local function rememberScroll(key: string, frame: ScrollingFrame)
	if scrollMemory[key] then
		frame.CanvasPosition = scrollMemory[key]
	end
	frame:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		scrollMemory[key] = frame.CanvasPosition
	end)
end

local function fmtTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

---------------------------------------------------------------------------
-- Threads Clothing
---------------------------------------------------------------------------
local threadsCategory = "All"
local threadsGroup = "All"
local selectedId: string? = nil
local selectedVariant = 1

local function previewSelected()
	local item = selectedId and ITEMS[selectedId]
	if not item or not state then
		return
	end
	local look = currentLook()
	look.equipped[item.slot] = item.id
	look.colours[item.slot] = selectedVariant
	startPreview(look)
end

renderers.Threads = function(root: Frame, opts: any)
	if opts.category then
		threadsCategory = opts.category
		threadsGroup = "All"
		opts.category = nil
	end
	if opts.group then
		threadsGroup = opts.group
		threadsCategory = "All"
		opts.group = nil
	end
	if not state then
		UI.label({ Text = "Loading the catalog...", Size = UDim2.new(1, 0, 0, 30), Parent = root })
		return
	end

	local cats = hscroll(root, 0, 28)
	local catList = { "All" }
	for _, c in ShopsConfig.CATEGORIES do
		table.insert(catList, c)
	end
	for i, c in catList do
		chip(cats, c, threadsCategory == c, ShopsConfig.CATEGORY_COLORS[c] or colors.accent, i, function()
			threadsCategory = c
			scrollMemory.Threads = Vector2.zero
			render()
		end)
	end
	local groups = hscroll(root, 34, 26)
	local groupList = { "All" }
	for _, g in ShopsConfig.GROUPS do
		table.insert(groupList, g)
	end
	for i, g in groupList do
		chip(groups, g, threadsGroup == g, Color3.fromRGB(230, 230, 235), i, function()
			threadsGroup = g
			scrollMemory.Threads = Vector2.zero
			render()
		end)
	end

	local DETAIL_H = 172
	local list = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 68),
		Size = UDim2.new(1, 0, 1, -68 - DETAIL_H - 6),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		Parent = root,
	}, {
		UI.new("UIGridLayout", { CellSize = UDim2.new(0.5, -5, 0, 58), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		UI.new("UIPadding", { PaddingRight = UDim.new(0, 6) }),
	})
	local shown = 0
	for i, item in ShopsConfig.ITEM_LIST do
		local catOk = threadsCategory == "All" or item.category == threadsCategory
		local groupOk = threadsGroup == "All" or ShopsConfig.SLOT_GROUP[item.slot] == threadsGroup
		if catOk and groupOk then
			shown += 1
			local first = item.variants[1]
			local isSel = selectedId == item.id
			local cell = UI.button({ Text = "", LayoutOrder = i, BackgroundColor3 = if isSel then Color3.fromRGB(48, 48, 62) else colors.panelLight, Parent = list })
			if isSel then
				UI.stroke(colors.accent, 2).Parent = cell
			end
			local sw = swatch(cell, first.c1, first.c2, 34, false, nil)
			sw.Position = UDim2.fromOffset(8, 12)
			UI.label({ Text = item.name, Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(50, 8), Size = UDim2.new(1, -56, 0, 18), Parent = cell })
			local tag, tagColor
			if wearing(item) then
				tag, tagColor = "WEARING", BLUE
			elseif owns(item.id) then
				tag, tagColor = "OWNED", GREEN
			else
				tag, tagColor = UI.formatCash(item.price), colors.cash
			end
			UI.label({ Text = tag, Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = tagColor, Position = UDim2.fromOffset(50, 30), Size = UDim2.new(1, -56, 0, 16), Parent = cell })
			cell.Activated:Connect(function()
				selectedId = item.id
				selectedVariant = if state.equipped[item.slot] == item.id then (state.colours[item.slot] or 1) else 1
				previewSelected()
				render()
			end)
		end
	end
	if shown == 0 then
		UI.label({ Text = "Nothing here.", TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 30), Parent = list })
	end
	rememberScroll("Threads", list)

	-- detail
	local detail = UI.new("Frame", {
		BackgroundColor3 = Color3.fromRGB(28, 28, 36),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, DETAIL_H),
		Parent = root,
	}, { UI.corner(12), UI.padding(10) })
	local item = selectedId and ITEMS[selectedId]
	if not item then
		UI.label({ Text = "Tap anything to try it on.\nRotate the view with the arrows below.", TextWrapped = true, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = detail })
		return
	end
	local variant = item.variants[selectedVariant] or item.variants[1]
	UI.label({ Text = item.name, Font = UI.FONT_BLACK, TextSize = 17, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -90, 0, 20), Parent = detail })
	UI.label({ Text = UI.formatCash(item.price), Font = UI.FONT_BLACK, TextSize = 17, TextColor3 = colors.cash, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(90, 20), Parent = detail })
	UI.label({ Text = item.category:upper() .. "  ·  " .. ShopsConfig.SLOT_LABELS[item.slot]:upper(), Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = ShopsConfig.CATEGORY_COLORS[item.category] or colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 14), Parent = detail })
	UI.label({ Text = item.desc, TextSize = 12, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 0, 28), Parent = detail })
	local swatches = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 70), Size = UDim2.new(1, 0, 0, 30), Parent = detail }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Center }),
	})
	for v, var in item.variants do
		swatch(swatches, var.c1, var.c2, 26, v == selectedVariant, function()
			selectedVariant = v
			previewSelected()
			render()
		end)
	end
	UI.label({ Text = variant.name, Font = UI.FONT_BOLD, TextSize = 13, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 26), Parent = swatches })

	local by = UDim2.new(0, 0, 1, -40)
	local half = UDim2.new(0.5, -4, 0, 40)
	actionButton(detail, if previewing then "STOP TRY-ON" else "TRY ON", colors.panelLight, by, half, function()
		if previewing then
			endPreview()
		else
			previewSelected()
		end
		render()
	end)
	local right = UDim2.new(0.5, 4, 1, -40)
	if not owns(item.id) then
		actionButton(detail, "BUY " .. UI.formatCash(item.price), GREEN, right, half, function()
			act("BuyItem", item.id)
			render()
		end)
	elseif wearing(item, selectedVariant) then
		if ShopsConfig.REQUIRED_SLOTS[item.slot] then
			UI.label({ Text = "WEARING ✓", Font = UI.FONT_BLACK, TextSize = 14, TextColor3 = BLUE, TextXAlignment = Enum.TextXAlignment.Center, Position = right, Size = half, Parent = detail })
		else
			actionButton(detail, "TAKE OFF", Color3.fromRGB(90, 90, 105), right, half, function()
				endPreview()
				act("Unequip", item.slot)
				render()
			end)
		end
	else
		actionButton(detail, "EQUIP", BLUE, right, half, function()
			endPreview()
			act("Equip", item.id, selectedVariant)
			render()
		end)
	end
end

---------------------------------------------------------------------------
-- Closet (wardrobe)
---------------------------------------------------------------------------
local closetSlot = "top"
local closetVariant: { [string]: number } = {}
local renaming: number? = nil

local function outfitsCard(parent: Instance, order: number, rerender: () -> ())
	local ROW = 62
	local box = card(parent, 30 + #state.outfits * ROW, order)
	UI.label({ Text = "SAVED OUTFITS", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = box })
	for i, outfit in state.outfits do
		local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 22 + (i - 1) * ROW), Size = UDim2.new(1, 0, 0, ROW - 6), Parent = box })
		if renaming == i then
			local input = UI.new("TextBox", {
				Text = outfit.name,
				PlaceholderText = "Outfit name",
				ClearTextOnFocus = false,
				Font = UI.FONT_BOLD,
				TextSize = 14,
				TextColor3 = colors.text,
				BackgroundColor3 = colors.panel,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -66, 0, 34),
				Parent = row,
			}, { UI.corner(8), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })
			local submitted = false
			local function submit()
				if submitted then
					return
				end
				submitted = true
				renaming = nil
				act("RenameOutfit", i, input.Text)
				rerender()
			end
			input.FocusLost:Connect(function(enter)
				if enter then
					submit()
				end
			end)
			actionButton(row, "OK", BLUE, UDim2.new(1, -60, 0, 0), UDim2.fromOffset(60, 34), submit)
			task.defer(function()
				input:CaptureFocus()
			end)
		else
			UI.label({ Text = outfit.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -70, 0, 18), Parent = row })
			UI.label({ Text = if outfit.saved then "Saved" else "Empty", TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(66, 18), Parent = row })
			local third = UDim2.new(1 / 3, -4, 0, 30)
			if outfit.saved then
				actionButton(row, "WEAR", BLUE, UDim2.fromOffset(0, 22), third, function()
					if inVehicle() then
						setStatus("Not while you're in a vehicle.", false)
						return
					end
					endPreview()
					act("WearOutfit", i)
					rerender()
				end)
			end
			actionButton(row, "SAVE FIT", GREEN, UDim2.new(1 / 3, 2, 0, 22), third, function()
				act("SaveOutfit", i)
				rerender()
			end)
			actionButton(row, "RENAME", colors.panel, UDim2.new(2 / 3, 4, 0, 22), third, function()
				renaming = i
				rerender()
			end)
		end
	end
end

local function avatarCard(parent: Instance, order: number, rerender: () -> ())
	local box = card(parent, 64, order)
	UI.label({ Text = "Use my Roblox avatar", Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -90, 0, 18), Parent = box })
	UI.label({ Text = if state.useRobloxAvatar then "Showing your real avatar look." else "Showing your CITY GRIND look.", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, -90, 0, 26), Parent = box })
	actionButton(box, if state.useRobloxAvatar then "ON" else "OFF", if state.useRobloxAvatar then GREEN else Color3.fromRGB(90, 90, 105), UDim2.new(1, -80, 0, 4), UDim2.fromOffset(80, 36), function()
		if inVehicle() then
			setStatus("Not while you're in a vehicle.", false)
			return
		end
		endPreview()
		act("SetAvatar", not state.useRobloxAvatar)
		rerender()
	end)
end

renderers.Closet = function(root: Frame)
	if not state then
		UI.label({ Text = "Loading your closet...", Size = UDim2.new(1, 0, 0, 30), Parent = root })
		return
	end
	local list = vlist(root, 0)
	avatarCard(list, 1, render)
	outfitsCard(list, 2, render)
	if previewing then
		local reset = actionButton(list, "STOP PREVIEW", colors.panelLight, UDim2.new(), UDim2.new(1, 0, 0, 34), function()
			endPreview()
			render()
		end)
		reset.LayoutOrder = 3
	end
	sectionTitle(list, "YOUR CLOTHES", 4)
	local slots = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		LayoutOrder = 5,
		Parent = list,
	}, { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	for i, slot in ShopsConfig.SLOTS do
		chip(slots, ShopsConfig.SLOT_LABELS[slot], closetSlot == slot, colors.accent, i, function()
			closetSlot = slot
			render()
		end)
	end

	local any = false
	for i, item in ShopsConfig.ITEM_LIST do
		if item.slot == closetSlot and owns(item.id) then
			any = true
			local row = card(list, 84, 10 + i)
			local v = closetVariant[item.id] or (if state.equipped[item.slot] == item.id then state.colours[item.slot] else 1) or 1
			local variant = item.variants[v] or item.variants[1]
			UI.label({ Text = item.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -96, 0, 18), Parent = row })
			UI.label({ Text = variant.name, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, -96, 0, 14), Parent = row })
			local sw = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, -96, 0, 28), Parent = row }, {
				UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }),
			})
			for index, var in item.variants do
				swatch(sw, var.c1, var.c2, 24, index == v, function()
					closetVariant[item.id] = index
					local look = currentLook()
					look.equipped[item.slot] = item.id
					look.colours[item.slot] = index
					startPreview(look)
					render()
				end)
			end
			local pos, size = UDim2.new(1, -88, 0, 14), UDim2.fromOffset(88, 36)
			if wearing(item, v) then
				if ShopsConfig.REQUIRED_SLOTS[item.slot] then
					UI.label({ Text = "WEARING", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = BLUE, TextXAlignment = Enum.TextXAlignment.Center, Position = pos, Size = size, Parent = row })
				else
					actionButton(row, "TAKE OFF", Color3.fromRGB(90, 90, 105), pos, size, function()
						if inVehicle() then
							setStatus("Not while you're in a vehicle.", false)
							return
						end
						endPreview()
						act("Unequip", item.slot)
						render()
					end)
				end
			else
				actionButton(row, "EQUIP", BLUE, pos, size, function()
					if inVehicle() then
						setStatus("Not while you're in a vehicle.", false)
						return
					end
					endPreview()
					act("Equip", item.id, v)
					closetVariant[item.id] = nil
					render()
				end)
			end
		end
	end
	if not any then
		local empty = card(list, 44, 50)
		UI.label({ Text = "Nothing here yet. Threads Clothing sells " .. ShopsConfig.SLOT_LABELS[closetSlot]:lower() .. ".", TextWrapped = true, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1), Parent = empty })
	end
	rememberScroll("Closet", list)
end

---------------------------------------------------------------------------
-- Fresh Cuts Barber
---------------------------------------------------------------------------
local cutHair, cutColor, cutFacial = "", "black", ""

local function previewCut()
	if not state then
		return
	end
	local look = currentLook()
	look.hair, look.hairColor, look.facial = cutHair, cutColor, cutFacial
	startPreview(look)
end

renderers.Barber = function(root: Frame, opts: any)
	if not state then
		UI.label({ Text = "Loading...", Size = UDim2.new(1, 0, 0, 30), Parent = root })
		return
	end
	if opts.fresh ~= false then
		opts.fresh = false
		cutHair, cutColor, cutFacial = state.hair, state.hairColor, state.facial
		previewCut()
	end
	local list = vlist(root, 0)
	if state.useRobloxAvatar then
		local note = card(list, 46, 0)
		UI.label({ Text = "A cut switches you from your Roblox avatar to your CITY GRIND look.", TextWrapped = true, TextSize = 12, TextColor3 = colors.stamina, Size = UDim2.fromScale(1, 1), Parent = note })
	end

	local function optionGrid(title: string, order: number, options: { any }, selected: string, onPick: (string) -> (), colourMode: boolean)
		sectionTitle(list, title, order)
		local rowsNeeded = math.ceil(#options / 3)
		local grid = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, rowsNeeded * 50 - 6), LayoutOrder = order + 1, Parent = list }, {
			UI.new("UIGridLayout", { CellSize = UDim2.new(1 / 3, -4, 0, 44), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		for i, option in options do
			local isSel = option.id == selected
			local b = UI.button({ Text = "", LayoutOrder = i, BackgroundColor3 = if isSel then Color3.fromRGB(50, 50, 66) else colors.panelLight, Parent = grid })
			if isSel then
				UI.stroke(colors.accent, 2).Parent = b
			end
			local textX = 8
			if colourMode then
				local dot = swatch(b, option.color, option.color, 20, false, nil)
				dot.Position = UDim2.fromOffset(6, 12)
				textX = 30
			end
			UI.label({ Text = option.name, Font = UI.FONT_BOLD, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(textX, 5), Size = UDim2.new(1, -textX - 4, 0, 16), Parent = b })
			UI.label({ Text = if option.price > 0 then (if colourMode then "+" else "") .. "$" .. option.price else "Free", TextSize = 11, TextColor3 = colors.cash, Position = UDim2.fromOffset(textX, 23), Size = UDim2.new(1, -textX - 4, 0, 14), Parent = b })
			b.Activated:Connect(function()
				onPick(option.id)
				previewCut()
				render()
			end)
		end
	end
	optionGrid("HAIRSTYLE", 1, ShopsConfig.HAIR_STYLES, cutHair, function(id)
		cutHair = id
	end, false)
	optionGrid("HAIR COLOUR", 3, ShopsConfig.HAIR_COLORS, cutColor, function(id)
		cutColor = id
	end, true)
	optionGrid("FACIAL HAIR", 5, ShopsConfig.FACIAL_HAIR, cutFacial, function(id)
		cutFacial = id
	end, false)

	local price = ShopsConfig.cutPrice(cutHair, cutColor, cutFacial) or 0
	local pay = card(list, 60, 20)
	UI.label({ Text = "TOTAL", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.fromOffset(100, 14), Parent = pay })
	UI.label({ Text = UI.formatCash(price), Font = UI.FONT_BLACK, TextSize = 22, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 14), Size = UDim2.fromOffset(110, 26), Parent = pay })
	actionButton(pay, "RESET", colors.panel, UDim2.new(1, -206, 0, 2), UDim2.fromOffset(80, 36), function()
		cutHair, cutColor, cutFacial = state.hair, state.hairColor, state.facial
		previewCut()
		render()
	end)
	actionButton(pay, "PAY " .. UI.formatCash(price), GREEN, UDim2.new(1, -120, 0, 2), UDim2.fromOffset(120, 36), function()
		endPreview()
		if act("Barber", cutHair, cutColor, cutFacial) then
			cutHair, cutColor, cutFacial = state.hair, state.hairColor, state.facial
		else
			previewCut()
		end
		render()
	end)
	UI.label({ Text = "Every visit is at least " .. UI.formatCash(ShopsConfig.MIN_CUT_PRICE) .. ". Colour only counts on a barber style or facial hair.", TextWrapped = true, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 21, Parent = list })
	rememberScroll("Barber", list)
end

---------------------------------------------------------------------------
-- Corner Mart + Mama's Kitchen
---------------------------------------------------------------------------
local function foodRow(list: Instance, food: ShopsConfig.Food, order: number, buttonText: string?, onBuy: (() -> ())?)
	local row = card(list, 66, order)
	UI.label({ Text = food.icon, TextSize = 28, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(36, 46), Parent = row })
	UI.label({ Text = food.name, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -140, 0, 18), Parent = row })
	UI.label({ Text = food.desc, TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(44, 19), Size = UDim2.new(1, -140, 0, 28), Parent = row })
	if buttonText and onBuy then
		actionButton(row, buttonText, GREEN, UDim2.new(1, -88, 0, 5), UDim2.fromOffset(88, 36), onBuy)
	else
		UI.label({ Text = buttonText or "", Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.stamina, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new(1, -88, 0, 5), Size = UDim2.fromOffset(88, 36), Parent = row })
	end
end

local function buffLines(): { string }
	local lines = {}
	local now = os.time()
	local boost = (player:GetAttribute("StaminaBoostUntil") or 0) - now
	if boost > 0 then
		table.insert(lines, "⚡ Hydrated " .. fmtTime(boost))
	end
	local fed = (player:GetAttribute("WellFedUntil") or 0) - now
	if fed > 0 then
		table.insert(lines, "🍽️ Well Fed " .. fmtTime(fed))
	end
	return lines
end

renderers.Mart = function(root: Frame)
	local list = vlist(root, 0)
	local lines = buffLines()
	if #lines > 0 then
		local b = card(list, 36, 0)
		UI.label({ Text = table.concat(lines, "   "), Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.stamina, Size = UDim2.fromScale(1, 1), Parent = b })
	end
	for i, food in ShopsConfig.MART do
		local wait = if food.strengthXP and state then state.proteinReadyAt - os.time() else 0
		if wait > 0 then
			foodRow(list, food, i, "Ready in " .. fmtTime(wait), nil)
		else
			foodRow(list, food, i, "BUY " .. UI.formatCash(food.price), function()
				act("BuyFood", food.id)
				render()
			end)
		end
	end
	rememberScroll("Mart", list)
end

renderers.Kitchen = function(root: Frame)
	local list = vlist(root, 0)
	local pending = state and state.mealPending or ""
	if pending ~= "" then
		local meal = ShopsConfig.findOption(ShopsConfig.MEALS, pending)
		local b = card(list, 48, 0)
		UI.label({ Text = "Your " .. (if meal then meal.name else "meal") .. " is ready. Sit at any table to eat it for the full Well Fed buff.", TextWrapped = true, Font = UI.FONT_BOLD, TextSize = 12, TextColor3 = colors.stamina, Size = UDim2.fromScale(1, 1), Parent = b })
	end
	for i, meal in ShopsConfig.MEALS do
		if pending ~= "" then
			foodRow(list, meal, i, UI.formatCash(meal.price), nil)
		else
			foodRow(list, meal, i, "ORDER " .. UI.formatCash(meal.price), function()
				if act("OrderMeal", meal.id) then
					closePanel()
				else
					render()
				end
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Buff chips above the stamina bar
---------------------------------------------------------------------------
local function buildBuffChips()
	local holder = UI.new("Frame", {
		Name = "Buffs",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -48),
		Size = UDim2.fromOffset(360, 24),
		Parent = gui,
	}, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6) }),
	})
	HUD.slot("bottomCenter", holder, 10)
	local chips: { [string]: TextLabel } = {}
	local function chipFor(key: string, color: Color3): TextLabel
		if not chips[key] then
			chips[key] = UI.label({
				Text = "",
				Font = UI.FONT_BOLD,
				TextSize = 12,
				TextColor3 = Color3.new(0, 0, 0),
				TextXAlignment = Enum.TextXAlignment.Center,
				BackgroundColor3 = color,
				BackgroundTransparency = 0.05,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, 22),
				Parent = holder,
			}, { UI.corner(11), UI.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })
		end
		return chips[key]
	end
	task.spawn(function()
		while gui.Parent do
			local now = os.time()
			local boost = (player:GetAttribute("StaminaBoostUntil") or 0) - now
			local fed = (player:GetAttribute("WellFedUntil") or 0) - now
			local meal = player:GetAttribute("MealPending") or ""
			local b = chipFor("boost", colors.stamina)
			b.Visible = boost > 0
			b.Text = "⚡ HYDRATED " .. fmtTime(boost)
			local f = chipFor("fed", Color3.fromRGB(255, 170, 110))
			f.Visible = fed > 0
			f.Text = "🍽️ WELL FED " .. fmtTime(fed)
			local m = chipFor("meal", Color3.fromRGB(240, 240, 245))
			m.Visible = meal ~= ""
			m.Text = "🍔 SIT AT A TABLE TO EAT"
			holder.Visible = b.Visible or f.Visible or m.Visible -- takes no HUD space when empty
			task.wait(0.5)
		end
	end)
end

---------------------------------------------------------------------------
-- Building the panel
---------------------------------------------------------------------------
local function applyScale()
	local camera = Workspace.CurrentCamera
	if not camera or not panelScale then
		return
	end
	local vp = camera.ViewportSize
	panelScale.Scale = math.clamp(math.min((vp.Y - 30) / PANEL_H, (vp.X * 0.55) / PANEL_W), 0.45, 1)
end

local function buildGui()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindShops",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 6,
		Parent = player:WaitForChild("PlayerGui"),
	})
	panel = UI.new("Frame", {
		Name = "ShopPanel",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.04,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		Visible = false,
		Parent = gui,
	}, { UI.corner(18), UI.stroke(Color3.fromRGB(70, 70, 82), 1.5), UI.padding(14) })
	panelScale = UI.new("UIScale", { Parent = panel })
	titleLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 22, Size = UDim2.new(1, -50, 0, 26), Parent = panel })
	subtitleLabel = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, -150, 0, 16), Parent = panel })
	local cashLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = colors.cash, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -46, 0, 26), Size = UDim2.fromOffset(110, 16), Parent = panel })
	local function refreshCash()
		cashLabel.Text = UI.formatCash(player:GetAttribute("Cash") or 0)
	end
	player:GetAttributeChangedSignal("Cash"):Connect(refreshCash)
	refreshCash()
	local close = UI.button({ Text = "✕", TextSize = 16, BackgroundColor3 = colors.panelLight, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(36, 36), Parent = panel })
	close.Activated:Connect(closePanel)
	body = UI.new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 1, -50 - 26), Parent = panel })
	statusLabel = UI.label({ Text = "", TextSize = 12, Font = UI.FONT_BOLD, TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 20), Parent = panel })

	-- mirror view controls (touch / mouse; arrows or L1/R1 also turn)
	mirrorBar = UI.new("Frame", {
		Name = "MirrorBar",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.62, 0, 1, -80),
		Size = UDim2.fromOffset(236, 44),
		Visible = false,
		Parent = gui,
	}, { UI.corner(22), UI.padding(4) })
	local left = UI.button({ Text = "◀", TextSize = 18, BackgroundColor3 = colors.panelLight, Size = UDim2.fromOffset(52, 36), Parent = mirrorBar })
	mirrorLabel = UI.button({ Text = "MIRROR", TextSize = 12, BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(58, 0), Size = UDim2.fromOffset(112, 36), Parent = mirrorBar })
	local right = UI.button({ Text = "▶", TextSize = 18, BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(176, 0), Size = UDim2.fromOffset(52, 36), Parent = mirrorBar })
	left.Activated:Connect(function()
		mirrorYaw -= math.rad(30)
	end)
	right.Activated:Connect(function()
		mirrorYaw += math.rad(30)
	end)
	-- the middle button flips between a full-body and a close-up view
	mirrorLabel.Activated:Connect(function()
		mirrorHead = not mirrorHead
		mirrorLabel.Text = if mirrorHead then "CLOSE-UP" else "FULL BODY"
	end)

	applyScale()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end
	buildBuffChips()
end

---------------------------------------------------------------------------
-- Closet phone app
---------------------------------------------------------------------------
local function buildClosetApp(content: ScrollingFrame)
	local function open()
		Phone.clear(content)
		local s = fetchState()
		if not s then
			UI.label({ Text = "Your closet is still loading...", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
			return
		end
		local wrap = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = content }, {
			UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		local function rerender()
			task.defer(open)
		end
		local top = card(wrap, 82, 0)
		local count = #s.owned
		UI.label({ Text = "WARDROBE", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = top })
		UI.label({ Text = count .. " item" .. (if count == 1 then "" else "s") .. " owned", Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 18), Parent = top })
		actionButton(top, "OPEN DRESSING ROOM", BLUE, UDim2.fromOffset(0, 40), UDim2.new(1, 0, 0, 32), function()
			if inVehicle() then
				setStatus("Not while you're in a vehicle.", false)
				UI.label({ Text = "Get out of your vehicle to change.", TextColor3 = colors.danger, TextSize = 12, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 99, Parent = wrap })
				return
			end
			openPanel("Closet", { mirror = true })
		end)
		avatarCard(wrap, 1, rerender)
		outfitsCard(wrap, 2, rerender)
		local status = UI.label({ Text = "", TextSize = 12, Font = UI.FONT_BOLD, TextWrapped = true, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 3, Parent = wrap })
		if statusLabel and statusLabel.Text ~= "" and not mode then
			status.Text = statusLabel.Text
			status.TextColor3 = statusLabel.TextColor3
		end
	end
	return open
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Shops.start()
	Phone.addApp({ id = "Closet", label = "Closet", icon = "👕", color = Color3.fromRGB(200, 80, 150) }, buildClosetApp)

	task.spawn(function()
		buildGui()
		ShopGetState = remotes:WaitForChild("ShopGetState") :: RemoteFunction
		ShopAction = remotes:WaitForChild("ShopAction") :: RemoteFunction
		local ShopOpen = remotes:WaitForChild("ShopOpen") :: RemoteEvent
		ShopOpen.OnClientEvent:Connect(function(newMode: any, opts: any)
			if type(newMode) == "string" then
				if newMode == "Barber" then
					opts = { fresh = true }
				end
				openPanel(newMode, if type(opts) == "table" then opts else {})
			end
		end)

		-- Shop panels close when you leave the shop; the barber when you stand up.
		player:GetAttributeChangedSignal("Interior"):Connect(function()
			if mode and mode ~= "Closet" then
				closePanel()
			end
		end)
		local function bindCharacter(character: Model)
			closePanel()
			table.clear(recorded)
			previewFolder = nil
			previewing = false
			local h = character:WaitForChild("Humanoid", 10)
			if h and h:IsA("Humanoid") then
				h:GetPropertyChangedSignal("SeatPart"):Connect(function()
					if mode == "Barber" and not h.SeatPart then
						closePanel()
					end
				end)
				h.Died:Connect(closePanel)
			end
		end
		player.CharacterAdded:Connect(bindCharacter)
		if player.Character then
			task.spawn(bindCharacter, player.Character)
		end
		-- live countdowns in the Mart panel
		while true do
			task.wait(1)
			if mode == "Mart" and state and (#buffLines() > 0 or state.proteinReadyAt > os.time() - 1) then
				render()
			end
		end
	end)
end

return Shops
