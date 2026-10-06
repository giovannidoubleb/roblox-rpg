-- CITY GRIND: Camera + Gallery apps (sections 30-33, 59, 86).
--
-- Camera: full-screen photo mode. Hides the HUD and other game UI, selfie / first /
-- third person / car orbit modes, zoom slider, filter carousel with a live preview
-- (a local ColorCorrectionEffect), pose picker + group pose for your party, 3s/10s
-- timer, grid overlay, shutter (button, V, gamepad R2). Every shot is saved as a
-- scene snapshot in your Gallery (server validated) and, where Roblox allows it, also
-- captured as a real screenshot you can SAVE TO DEVICE or SHARE with Roblox's prompts.
-- Gallery: your saved photos (rendered in ViewportFrames, a page at a time), full view,
-- delete, Private / Public, profile picture, post to CityGram.
--
-- Public client API (used by CityGram):
--   Media.render(viewport, snapshot, maxParts?)        draw a snapshot
--   Media.openViewer({ snap, title, sub?, actions?, input? })  full-screen photo view
--   Media.fetchPhoto(photoId) -> snapshot?             (own, public or profile photos)
--   Media.openCamera() / Media.isCameraOpen()

local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local MediaConfig = require(shared:WaitForChild("MediaConfig"))
local SceneSnapshot = require(shared:WaitForChild("SceneSnapshot"))

local player = Players.LocalPlayer
local colors = UI.colors

-- Roblox's screenshot API (not available everywhere, so every use is pcall'd)
local CaptureService: any = nil
pcall(function()
	CaptureService = game:GetService("CaptureService")
end)

local Media = {}

local CAMERA_COLOR = Color3.fromRGB(60, 60, 70)
local GALLERY_COLOR = Color3.fromRGB(230, 120, 170)
local GOOD = Color3.fromRGB(50, 170, 90)
local BLUE = Color3.fromRGB(40, 120, 220)
local DIM = Color3.fromRGB(60, 60, 72)
local GUI_NAME = "CityGrindMedia"

local MediaAction: RemoteFunction? = nil
local gui: ScreenGui? = nil

local photoCache: { [string]: any } = {} -- photo id -> snapshot
local deviceCaptures: { [string]: string } = {} -- photo id -> screenshot content id (this session)

---------------------------------------------------------------------------
-- Server calls
---------------------------------------------------------------------------
local function act(action: string, a: any?, b: any?): (boolean, string?, any)
	if not MediaAction then
		return false, "Still connecting...", nil
	end
	local ok, success, message, data = pcall(function()
		return (MediaAction :: RemoteFunction):InvokeServer(action, a, b)
	end)
	if not ok then
		return false, "Couldn't reach the server.", nil
	end
	return success == true, message, data
end

local function optionalClient(name: string): any
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end

function Media.render(viewport: ViewportFrame, snap: any, maxParts: number?)
	local ok, err = pcall(SceneSnapshot.render, viewport, snap, { maxParts = maxParts })
	if not ok then
		warn("[CityGrind] photo render failed:", err)
	end
end

function Media.fetchPhoto(photoId: string): any
	if photoCache[photoId] then
		return photoCache[photoId]
	end
	local ok, _, data = act("get", photoId)
	if ok and type(data) == "table" and type(data.snap) == "table" then
		photoCache[photoId] = data.snap
		return data.snap
	end
	return nil
end

---------------------------------------------------------------------------
-- Device screenshots (Roblox CaptureService)
---------------------------------------------------------------------------
local function saveToDevice(photoId: string)
	local content = deviceCaptures[photoId]
	if not content then
		HUD.push("CAMERA", "No device screenshot for this photo.")
		return
	end
	local ok = CaptureService ~= nil and pcall(function()
		CaptureService:PromptSaveCapturesToGallery({ content }, function(results)
			local saved = type(results) == "table" and results[content] == true
			if saved then
				HUD.push("CAMERA", "Saved to your device.")
			end
		end)
	end)
	if not ok then
		HUD.push("CAMERA", "Saving to your device isn't available here.")
	end
end

local function shareCapture(photoId: string)
	local content = deviceCaptures[photoId]
	if not content then
		return
	end
	local ok = CaptureService ~= nil and pcall(function()
-- selene: allow(undefined_variable)
		CaptureService:PromptShareCapture(Content.fromUri(content), "", function() end, function() end)
	end)
	if not ok then
		HUD.push("CAMERA", "Sharing isn't available on this device.")
	end
end

---------------------------------------------------------------------------
-- Full-screen viewer (also used by CityGram and profiles)
---------------------------------------------------------------------------
type ViewerAction = { label: string, color: Color3?, fn: () -> () }
type ViewerOpts = {
	snap: any,
	title: string?,
	sub: string?,
	actions: { ViewerAction }?,
	input: { placeholder: string, button: string, max: number, fn: (string) -> () }?,
}

local viewer: TextButton
local viewerPanel: Frame
local viewerView: ViewportFrame
local viewerTitle: TextLabel
local viewerSub: TextLabel
local viewerActions: Frame
local viewerInputRow: Frame
local viewerInput: TextBox
local viewerInputButton: TextButton
local viewerInputFn: ((string) -> ())? = nil

local function closeViewer()
	if viewer then
		viewer.Visible = false
		for _, child in viewerView:GetChildren() do
			if not child:IsA("UICorner") and not child:IsA("UIAspectRatioConstraint") then
				child:Destroy()
			end
		end
	end
	ContextActionService:UnbindAction("CityGrindViewerClose")
end
Media.closeViewer = closeViewer

local function buildViewer(parent: ScreenGui)
	viewer = UI.new("TextButton", {
		Name = "Viewer",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	})
	viewer.Activated:Connect(closeViewer)
	viewerPanel = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.92, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 21,
		Active = true,
		Parent = viewer,
	}, {
		UI.corner(16),
		UI.padding(12),
		UI.new("UISizeConstraint", { MaxSize = Vector2.new(680, math.huge) }),
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local top = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 1, ZIndex = 21, Parent = viewerPanel })
	viewerTitle = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 17, Size = UDim2.new(1, -44, 0, 20), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 21, Parent = top })
	viewerSub = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, -44, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 21, Parent = top })
	local close = UI.button({ Text = "✕", TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(36, 36), ZIndex = 22, Parent = top })
	close.Activated:Connect(closeViewer)
	viewerView = UI.new("ViewportFrame", {
		BackgroundColor3 = Color3.fromRGB(30, 30, 40),
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = 2,
		ZIndex = 21,
		Parent = viewerPanel,
	}, { UI.corner(10) })
	-- keep a 16:10 photo whatever the panel width
	UI.new("UIAspectRatioConstraint", { AspectRatio = 1.6, DominantAxis = Enum.DominantAxis.Width, Parent = viewerView })
	viewerView.Size = UDim2.new(1, 0, 0, 100)
	viewerInputRow = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 3, Visible = false, ZIndex = 21, Parent = viewerPanel })
	viewerInput = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, -96, 1, 0),
		ZIndex = 21,
		Parent = viewerInputRow,
	}, { UI.corner(10), UI.padding(8) })
	viewerInputButton = UI.button({ Text = "POST", TextSize = 14, BackgroundColor3 = GOOD, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 88, 1, 0), ZIndex = 22, Parent = viewerInputRow })
	viewerInputButton.Activated:Connect(function()
		if viewerInputFn then
			viewerInputFn(viewerInput.Text)
		end
	end)
	viewerActions = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, ZIndex = 21, Parent = viewerPanel }, {
		UI.new("UIGridLayout", { CellSize = UDim2.new(0.25, -6, 0, 36), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

function Media.openViewer(opts: ViewerOpts)
	if not viewer then
		return
	end
	viewerTitle.Text = opts.title or "Photo"
	viewerSub.Text = opts.sub or ""
	for _, child in viewerActions:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	for i, a in (opts.actions or {}) :: { ViewerAction } do
		local b = UI.button({ Text = a.label, TextSize = 12, TextWrapped = true, BackgroundColor3 = a.color or DIM, LayoutOrder = i, ZIndex = 22, Parent = viewerActions })
		b.Activated:Connect(a.fn)
	end
	if opts.input then
		viewerInputRow.Visible = true
		viewerInput.Text = ""
		viewerInput.PlaceholderText = opts.input.placeholder
		viewerInputButton.Text = opts.input.button
		local max = opts.input.max
		viewerInputFn = function(text: string)
			if utf8.len(text) and (utf8.len(text) :: number) > max then
				HUD.push("TOO LONG", string.format("Keep it under %d characters.", max))
				return
			end
			(opts.input :: any).fn(text)
		end
	else
		viewerInputRow.Visible = false
		viewerInputFn = nil
	end
	local size = Workspace.CurrentCamera.ViewportSize
	local width = math.min(size.X * 0.92, 680, (size.Y - 200) * 1.6 + 24)
	viewerPanel.Size = UDim2.new(0, math.max(width, 240), 0, 0)
	viewer.Visible = true
	Media.render(viewerView, opts.snap, MediaConfig.RENDER_PARTS)
	ContextActionService:BindActionAtPriority("CityGrindViewerClose", function(_, state)
		if state == Enum.UserInputState.Begin then
			closeViewer()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3100, Enum.KeyCode.ButtonB)
end

local function describe(snap: any, extra: string?): string
	local bits = {}
	if type(snap.l) == "string" and snap.l ~= "" then
		table.insert(bits, "📍 " .. snap.l)
	end
	if type(snap.k) == "number" then
		table.insert(bits, UI.formatClock(snap.k))
	end
	local f = MediaConfig.filter(snap.fl)
	if f.id ~= "None" then
		table.insert(bits, f.label)
	end
	if type(snap.p) == "table" and #snap.p > 0 then
		local names = {}
		for i = 1, math.min(#snap.p, 3) do
			table.insert(names, tostring(snap.p[i].n))
		end
		local more = #snap.p - #names
		table.insert(bits, "with " .. table.concat(names, ", ") .. (if more > 0 then " +" .. more else ""))
	end
	if extra then
		table.insert(bits, extra)
	end
	return table.concat(bits, "  ·  ")
end
Media.describe = describe

---------------------------------------------------------------------------
-- Camera mode
---------------------------------------------------------------------------
local cam = {
	active = false,
	mode = "third", -- "third" | "first" | "selfie" | "car"
	fov = MediaConfig.FOV_DEFAULT,
	filter = 1,
	timer = 0, -- 0 / 3 / 10
	grid = false,
	busy = false,
	countdownToken = 0,
	zoomDir = 0,
	orbitAngle = 0,
	orbitAuto = true,
	pose = "Flex",
	lastPhotoId = nil :: string?,
	lastSnap = nil :: any,
}
local saved: any = nil
local camUI: Frame
local liveOverlay: Frame
local gridFrame: Frame
local countdownLabel: TextLabel
local flashFrame: Frame
local statusLabel: TextLabel
local modeButtons: { [string]: TextButton } = {}
local filterChips: { TextButton } = {}
local zoomFill: Frame
local zoomKnob: Frame
local zoomLabel: TextLabel
local timerButton: TextButton
local gridButton: TextButton
local carRow: Frame
local lightsButton: TextButton
local orbitButton: TextButton
local poseRow: Frame
local lastThumb: ViewportFrame
local afterRow: Frame
local colorEffect: ColorCorrectionEffect? = nil

local function ownCar(): Model?
	local folder = SceneSnapshot.vehicleFolder()
	if not folder then
		return nil
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("Owner") == player.UserId then
			return m
		end
	end
	return nil
end

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function nearCar(): Model?
	local car = ownCar()
	local root = rootPart()
	if car and root and (car:GetPivot().Position - root.Position).Magnitude <= 30 then
		return car
	end
	return nil
end

-- True only when you sit in the driver's seat of your own spawned vehicle.
local function drivingOwnCar(car: Model?): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local driving = player:GetAttribute("Driving")
	return car ~= nil and seat ~= nil and seat:IsA("VehicleSeat") and seat:IsDescendantOf(car) and type(driving) == "string" and driving ~= ""
end

local function setStatus(text: string)
	statusLabel.Text = text
	statusLabel.Visible = text ~= ""
end

local function applyFilter()
	local f = MediaConfig.FILTERS[cam.filter]
	if colorEffect then
		colorEffect.Saturation = f.saturation
		colorEffect.Contrast = f.contrast
		colorEffect.Brightness = f.brightness
		colorEffect.TintColor = f.tint
	end
	SceneSnapshot.overlay(liveOverlay, f.id, 11)
	for i, chip in filterChips do
		local stroke = chip:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = if i == cam.filter then 0 else 1
		end
	end
end

local function updateZoomUI()
	local t = (cam.fov - MediaConfig.FOV_MIN) / (MediaConfig.FOV_MAX - MediaConfig.FOV_MIN)
	-- left = zoomed in (small FOV)
	zoomFill.Size = UDim2.fromScale(1 - t, 1)
	zoomKnob.Position = UDim2.new(1 - t, 0, 0.5, 0)
	zoomLabel.Text = string.format("ZOOM  %.1fx", MediaConfig.FOV_DEFAULT / cam.fov)
end

local function setFov(fov: number)
	cam.fov = math.clamp(fov, MediaConfig.FOV_MIN, MediaConfig.FOV_MAX)
	updateZoomUI()
end

local function refreshCarRow()
	local car = nearCar()
	modeButtons.car.Visible = car ~= nil
	carRow.Visible = car ~= nil and cam.mode == "car"
	lightsButton.Visible = drivingOwnCar(car) and shared:FindFirstChild("Remotes") ~= nil and (shared :: any).Remotes:FindFirstChild("VehicleLights") ~= nil
	if car then
		lightsButton.Text = if car:GetAttribute("Headlights") then "💡 LIGHTS ON" else "💡 LIGHTS OFF"
	end
	orbitButton.Text = if cam.orbitAuto then "⟲ ORBIT: AUTO" else "⟲ ORBIT: HOLD"
end

local function setMode(mode: string)
	if mode == "car" and not nearCar() then
		setStatus("Stand near your vehicle for car photos.")
		return
	end
	cam.mode = mode
	local camera = Workspace.CurrentCamera
	if mode == "first" then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		camera.CameraType = Enum.CameraType.Custom
	else
		player.CameraMode = Enum.CameraMode.Classic
		if mode == "third" then
			camera.CameraType = Enum.CameraType.Custom
		else
			camera.CameraType = Enum.CameraType.Scriptable
		end
	end
	for id, b in modeButtons do
		b.BackgroundColor3 = if id == mode then colors.accent else DIM
	end
	refreshCarRow()
	if mode == "first" and UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
		setStatus("First person: V shoots, M switches mode, Backspace exits.")
	else
		setStatus("")
	end
end

local function renderStep(dt: number)
	if not cam.active then
		return
	end
	local camera = Workspace.CurrentCamera
	if cam.zoomDir ~= 0 then
		setFov(cam.fov + cam.zoomDir * 40 * dt)
	end
	camera.FieldOfView = cam.fov
	local character = player.Character
	if cam.mode == "selfie" then
		local head = character and character:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			local root = rootPart()
			local facing = if root then root.CFrame else head.CFrame
			local eye = head.Position + Vector3.new(0, 0.15, 0)
			local pos = (facing * CFrame.new(0.9, 0, -4.2)).Position
			pos = Vector3.new(pos.X, eye.Y + 0.6, pos.Z)
			camera.CFrame = CFrame.lookAt(pos, eye)
		end
	elseif cam.mode == "car" then
		local car = nearCar()
		if not car then
			setMode("third")
			return
		end
		if cam.orbitAuto then
			cam.orbitAngle += dt * 0.35
		end
		local cf, size = car:GetBoundingBox()
		local radius = math.max(size.X, size.Z) * 0.9 + 7
		local center = cf.Position
		local pos = center + Vector3.new(math.cos(cam.orbitAngle) * radius, size.Y * 0.4 + 2.5, math.sin(cam.orbitAngle) * radius)
		camera.CFrame = CFrame.lookAt(pos, center)
	end
end

local function hideWorldUI(): any
	local state = { guis = {}, core = {} }
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for _, g in playerGui:GetChildren() do
			if g:IsA("ScreenGui") and g.Name ~= GUI_NAME and g.Name ~= "TouchGui" and g.Enabled then
				g.Enabled = false
				table.insert(state.guis, g)
			end
		end
	end
	for _, t in { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Chat, Enum.CoreGuiType.Health, Enum.CoreGuiType.EmotesMenu } do
		local ok, enabled = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, t)
		if ok and enabled then
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, t, false)
			table.insert(state.core, t)
		end
	end
	return state
end

local function restoreWorldUI(state: any)
	for _, g in state.guis do
		if g.Parent then
			g.Enabled = true
		end
	end
	for _, t in state.core do
		pcall(StarterGui.SetCoreGuiEnabled, StarterGui, t, true)
	end
end

local CAMERA_ACTIONS = { "CGCamShutter", "CGCamExit", "CGCamFilter", "CGCamZoom", "CGCamMode" }

local function exitCamera()
	if not cam.active then
		return
	end
	cam.active = false
	cam.countdownToken += 1
	cam.zoomDir = 0
	RunService:UnbindFromRenderStep("CityGrindCamera")
	for _, name in CAMERA_ACTIONS do
		ContextActionService:UnbindAction(name)
	end
	if colorEffect then
		colorEffect:Destroy()
		colorEffect = nil
	end
	camUI.Visible = false
	countdownLabel.Visible = false
	local camera = Workspace.CurrentCamera
	if saved then
		player.CameraMode = saved.cameraMode
		player.CameraMaxZoomDistance = saved.maxZoom
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = saved.fov
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		restoreWorldUI(saved.ui)
		saved = nil
	end
	HUD.setVisible(true)
end
Media.closeCamera = exitCamera

local shoot: () -> ()

local function bindCameraActions()
	ContextActionService:BindActionAtPriority("CGCamShutter", function(_, state)
		if state == Enum.UserInputState.Begin then
			task.spawn(shoot)
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.V, Enum.KeyCode.ButtonR2)
	ContextActionService:BindActionAtPriority("CGCamExit", function(_, state)
		if state == Enum.UserInputState.Begin then
			exitCamera()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
	ContextActionService:BindActionAtPriority("CGCamFilter", function(_, state, input)
		if state == Enum.UserInputState.Begin then
			local step = if input.KeyCode == Enum.KeyCode.LeftBracket or input.KeyCode == Enum.KeyCode.ButtonL1 then -1 else 1
			cam.filter = (cam.filter - 1 + step) % #MediaConfig.FILTERS + 1
			applyFilter()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.LeftBracket, Enum.KeyCode.RightBracket, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
	ContextActionService:BindActionAtPriority("CGCamZoom", function(_, state, input)
		local zoomIn = input.KeyCode == Enum.KeyCode.DPadUp or input.KeyCode == Enum.KeyCode.Z
		if state == Enum.UserInputState.Begin then
			cam.zoomDir = if zoomIn then -1 else 1
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			cam.zoomDir = 0
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.DPadUp, Enum.KeyCode.DPadDown, Enum.KeyCode.Z, Enum.KeyCode.X)
	ContextActionService:BindActionAtPriority("CGCamMode", function(_, state)
		if state == Enum.UserInputState.Begin then
			local order = { "third", "first", "selfie", "car" }
			local i = table.find(order, cam.mode) or 1
			for step = 1, #order do
				local nextMode = order[(i - 1 + step) % #order + 1]
				if nextMode ~= "car" or nearCar() then
					setMode(nextMode)
					break
				end
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.M, Enum.KeyCode.ButtonY)
end

function Media.openCamera()
	if cam.active or not camUI then
		return
	end
	if not rootPart() then
		HUD.push("CAMERA", "You need to be in the city to take photos.")
		return
	end
	Phone.showPage("Home")
	Phone.setOpen(false)
	Media.closeViewer()
	local camera = Workspace.CurrentCamera
	saved = {
		fov = camera.FieldOfView,
		cameraMode = player.CameraMode,
		maxZoom = player.CameraMaxZoomDistance,
		ui = hideWorldUI(),
	}
	-- the server only accepts photos taken near you
	player.CameraMaxZoomDistance = math.max(player.CameraMinZoomDistance, math.min(saved.maxZoom, 60))
	HUD.setVisible(false)
	cam.active = true
	cam.fov = MediaConfig.FOV_DEFAULT
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "CityGrindCameraFilter"
	effect.Parent = Lighting
	colorEffect = effect
	camUI.Visible = true
	afterRow.Visible = false
	poseRow.Visible = false
	gridFrame.Visible = cam.grid
	setMode(if cam.mode == "car" and not nearCar() then "third" else cam.mode)
	applyFilter()
	updateZoomUI()
	RunService:BindToRenderStep("CityGrindCamera", Enum.RenderPriority.Camera.Value + 1, renderStep)
	bindCameraActions()
	setStatus("Tap the shutter, press V or R2.")
	task.delay(3, function()
		if cam.active and statusLabel.Text == "Tap the shutter, press V or R2." then
			setStatus("")
		end
	end)
end

function Media.isCameraOpen(): boolean
	return cam.active
end

local function showAfterShot(photoId: string)
	for _, child in afterRow:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	local function add(text: string, color: Color3, fn: () -> ())
		local b = UI.button({ Text = text, TextSize = 13, BackgroundColor3 = color, Size = UDim2.fromOffset(150, 36), Parent = afterRow })
		b.Activated:Connect(fn)
	end
	if deviceCaptures[photoId] then
		add("💾 SAVE TO DEVICE", BLUE, function()
			saveToDevice(photoId)
		end)
		add("↗ SHARE", DIM, function()
			shareCapture(photoId)
		end)
	end
	add("🖼 VIEW", DIM, function()
		local snap = photoCache[photoId]
		if snap then
			exitCamera()
			Media.openViewer({ snap = snap, title = "New photo", sub = describe(snap) })
		end
	end)
	poseRow.Visible = false
	afterRow.Visible = true
	local token = cam.countdownToken
	task.delay(8, function()
		if token == cam.countdownToken then
			afterRow.Visible = false
		end
	end)
end

shoot = function()
	if not cam.active or cam.busy then
		return
	end
	cam.busy = true
	cam.countdownToken += 1
	local token = cam.countdownToken
	if cam.timer > 0 then
		countdownLabel.Visible = true
		for n = cam.timer, 1, -1 do
			countdownLabel.Text = tostring(n)
			task.wait(1)
			if token ~= cam.countdownToken or not cam.active then
				countdownLabel.Visible = false
				cam.busy = false
				return
			end
		end
		countdownLabel.Visible = false
	end
	local camera = Workspace.CurrentCamera
	local filterId = MediaConfig.FILTERS[cam.filter].id
	local okCapture, _, request = pcall(SceneSnapshot.capture, camera, { filter = filterId, includeSelf = cam.mode ~= "first" })
	if not okCapture or not request then
		cam.busy = false
		setStatus("Couldn't take that photo.")
		return
	end

	-- real screenshot for the device, with our camera UI hidden for a moment
	local holder: { content: string?, photoId: string? } = {}
	camUI.Visible = false
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
	pcall(function()
		if not CaptureService then
			return
		end
		CaptureService:CaptureScreenshot(function(contentId)
			if type(contentId) == "string" and contentId ~= "" then
				holder.content = contentId
				if holder.photoId then
					deviceCaptures[holder.photoId] = contentId
				end
			end
		end)
	end)
	task.wait(0.12)
	if not cam.active then
		cam.busy = false
		return
	end
	camUI.Visible = true
	flashFrame.BackgroundTransparency = 0.1
	TweenService:Create(flashFrame, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()

	local ok, message, data = act("capture", request)
	cam.busy = false
	if ok and type(data) == "table" and type(data.meta) == "table" then
		local id = data.meta.id
		photoCache[id] = data.snap
		holder.photoId = id
		if holder.content then
			deviceCaptures[id] = holder.content
		end
		cam.lastPhotoId = id
		cam.lastSnap = data.snap
		lastThumb.Visible = true
		Media.render(lastThumb, data.snap, MediaConfig.THUMB_PARTS)
		setStatus(message or "Saved to your Gallery.")
		Phone.refresh("Gallery")
		task.delay(0.6, function()
			if cam.active and cam.lastPhotoId == id then
				showAfterShot(id)
			end
		end)
	else
		setStatus(message or "Couldn't save that photo.")
	end
end

---------------------------------------------------------------------------
-- Camera UI
---------------------------------------------------------------------------
local function chip(parent: Instance, text: string, width: number, color: Color3?): TextButton
	return UI.button({ Text = text, TextSize = 13, BackgroundColor3 = color or DIM, BackgroundTransparency = 0.15, Size = UDim2.fromOffset(width, 34), Parent = parent })
end

local function buildCameraUI(parent: ScreenGui)
	camUI = UI.new("Frame", { Name = "Camera", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = parent })
	liveOverlay = UI.new("Frame", { Name = "Lens", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = camUI })
	gridFrame = UI.new("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = camUI })
	for i = 1, 2 do
		UI.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.6, Position = UDim2.fromScale(i / 3, 0), Size = UDim2.new(0, 1, 1, 0), Parent = gridFrame })
		UI.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.6, Position = UDim2.fromScale(0, i / 3), Size = UDim2.new(1, 0, 0, 1), Parent = gridFrame })
	end
	flashFrame = UI.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = parent })
	countdownLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 120, TextStrokeTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 9, Parent = parent })

	-- top bar
	local top = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -24, 0, 34), Parent = camUI }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }),
	})
	local close = chip(top, "✕", 40, colors.danger)
	close.LayoutOrder = 1
	close.Activated:Connect(exitCamera)
	for i, m in { { "selfie", "🤳 SELFIE" }, { "first", "👁 1ST" }, { "third", "🎥 3RD" }, { "car", "🚗 CAR" } } do
		local b = chip(top, m[2], if m[1] == "selfie" then 92 else 70)
		b.LayoutOrder = 1 + i
		b.Activated:Connect(function()
			setMode(m[1])
		end)
		modeButtons[m[1]] = b
	end
	gridButton = chip(top, "# GRID", 72)
	gridButton.LayoutOrder = 10
	gridButton.Activated:Connect(function()
		cam.grid = not cam.grid
		gridFrame.Visible = cam.grid
		gridButton.BackgroundColor3 = if cam.grid then colors.accent else DIM
	end)
	timerButton = chip(top, "⏱ OFF", 72)
	timerButton.LayoutOrder = 11
	timerButton.Activated:Connect(function()
		cam.timer = if cam.timer == 0 then 3 elseif cam.timer == 3 then 10 else 0
		timerButton.Text = if cam.timer == 0 then "⏱ OFF" else "⏱ " .. cam.timer .. "s"
		timerButton.BackgroundColor3 = if cam.timer > 0 then colors.accent else DIM
	end)

	statusLabel = UI.label({
		Text = "",
		Font = UI.FONT_BOLD,
		TextSize = 15,
		TextStrokeTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 56),
		Size = UDim2.new(0.8, 0, 0, 22),
		Visible = false,
		Parent = camUI,
	})

	-- car tools (section 59)
	carRow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 84), Size = UDim2.new(1, -24, 0, 34), Visible = false, Parent = camUI }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	lightsButton = chip(carRow, "💡 LIGHTS", 130)
	lightsButton.Activated:Connect(function()
		local car = ownCar()
		local remote = (shared :: any):FindFirstChild("Remotes") and (shared :: any).Remotes:FindFirstChild("VehicleLights")
		if drivingOwnCar(car) and remote and remote:IsA("RemoteEvent") then
			remote:FireServer()
			task.delay(0.3, refreshCarRow)
		else
			setStatus("Get in the driver's seat to switch the lights.")
		end
	end)
	orbitButton = chip(carRow, "⟲ ORBIT: AUTO", 130)
	orbitButton.Activated:Connect(function()
		cam.orbitAuto = not cam.orbitAuto
		refreshCarRow()
	end)
	local left = chip(carRow, "◀", 44)
	left.Activated:Connect(function()
		cam.orbitAngle -= math.rad(20)
	end)
	local right = chip(carRow, "▶", 44)
	right.Activated:Connect(function()
		cam.orbitAngle += math.rad(20)
	end)

	-- bottom: filters, zoom, poses, shutter
	local bottom = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.new(1, -24, 0, 196), Parent = camUI })

	afterRow = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Visible = false, Parent = bottom }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6) }),
	})

	poseRow = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, 40),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		Visible = false,
		Parent = bottom,
	}, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local EmotesConfig = require(shared:WaitForChild("EmotesConfig"))
	local poseChips: { [string]: TextButton } = {}
	for i, id in MediaConfig.POSES do
		local emote = EmotesConfig.find(id)
		if emote then
			local b = chip(poseRow, emote.icon .. " " .. emote.name, 116)
			b.LayoutOrder = i
			poseChips[id] = b
			b.Activated:Connect(function()
				cam.pose = id
				for pid, pb in poseChips do
					pb.BackgroundColor3 = if pid == id then colors.accent else DIM
				end
				local Emotes = optionalClient("Emotes")
				if Emotes and Emotes.play then
					Emotes.play(id)
				end
			end)
		end
	end
	local group = chip(poseRow, "📣 GROUP POSE", 130, BLUE)
	group.LayoutOrder = 100
	group.Activated:Connect(function()
		local _, message = act("groupPose", cam.pose)
		setStatus(message or "")
	end)

	local filterRow = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(1, 0, 0, 40),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		Parent = bottom,
	}, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, f in MediaConfig.FILTERS do
		local b = chip(filterRow, "", 86)
		b.LayoutOrder = i
		b.BackgroundColor3 = SceneSnapshot.filterColor(Color3.fromRGB(120, 150, 190), f)
		b.BackgroundTransparency = 0.05
		UI.label({ Text = f.label, Font = UI.FONT_BOLD, TextSize = 13, TextStrokeTransparency = 0.5, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = b })
		UI.stroke(Color3.new(1, 1, 1), 2, 1).Parent = b
		b.Activated:Connect(function()
			cam.filter = i
			applyFilter()
		end)
		filterChips[i] = b
	end

	-- zoom slider
	local zoomRow = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 90), Size = UDim2.new(0, 300, 0, 22), Parent = bottom })
	zoomLabel = UI.label({ Text = "ZOOM", Font = UI.FONT_BOLD, TextSize = 12, TextStrokeTransparency = 0.5, Size = UDim2.new(0, 90, 1, 0), Parent = zoomRow })
	local track = UI.new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromRGB(40, 40, 50), BackgroundTransparency = 0.2, Position = UDim2.new(0, 96, 0.5, -4), Size = UDim2.new(1, -96, 0, 8), Parent = zoomRow }, { UI.corner(4) })
	zoomFill = UI.new("Frame", { BackgroundColor3 = colors.accent, Size = UDim2.fromScale(0.5, 1), Parent = track }, { UI.corner(4) })
	zoomKnob = UI.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(18, 18), Parent = track }, { UI.corner(9) })
	local dragging = false
	local function dragTo(x: number)
		local t = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		setFov(MediaConfig.FOV_MAX - t * (MediaConfig.FOV_MAX - MediaConfig.FOV_MIN))
	end
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragTo(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			dragTo(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	-- shutter row
	local shutterRow = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.new(0, 300, 0, 76), Parent = bottom })
	local poseToggle = UI.button({ Text = "🕺\nPOSE", TextSize = 12, BackgroundColor3 = DIM, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(64, 56), Parent = shutterRow })
	poseToggle.Activated:Connect(function()
		poseRow.Visible = not poseRow.Visible
		afterRow.Visible = false
	end)
	local shutter = UI.new("TextButton", {
		Text = "",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(72, 72),
		Parent = shutterRow,
	}, { UI.corner(36), UI.stroke(Color3.fromRGB(200, 200, 210), 4) })
	shutter.Activated:Connect(function()
		task.spawn(shoot)
	end)
	lastThumb = UI.new("ViewportFrame", {
		BackgroundColor3 = Color3.fromRGB(30, 30, 40),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(64, 56),
		Visible = false,
		Parent = shutterRow,
	}, { UI.corner(10), UI.stroke(Color3.new(1, 1, 1), 2) })
	local thumbButton = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(64, 56), ZIndex = 3, Parent = shutterRow })
	thumbButton.Activated:Connect(function()
		local id = cam.lastPhotoId
		if id then
			showAfterShot(id)
		end
	end)
end

---------------------------------------------------------------------------
-- Group pose requests
---------------------------------------------------------------------------
local poseCard: Frame
local poseText: TextLabel
local poseFrom = 0
local poseToken = 0

local function respondPose(accept: boolean)
	poseCard.Visible = false
	if poseFrom ~= 0 then
		task.spawn(act, "poseRespond", poseFrom, accept)
	end
	poseFrom = 0
	ContextActionService:UnbindAction("CGPoseAccept")
end

local function buildPoseCard(parent: ScreenGui)
	poseCard = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.05,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 150),
		Size = UDim2.fromOffset(300, 96),
		Visible = false,
		ZIndex = 15,
		Parent = parent,
	}, { UI.corner(14), UI.stroke(colors.accent, 1.5, 0.2), UI.padding(10) })
	poseText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 15, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 36), ZIndex = 15, Parent = poseCard })
	local yes = UI.button({ Text = "POSE", TextSize = 14, BackgroundColor3 = GOOD, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(0.5, -4, 0, 34), ZIndex = 16, Parent = poseCard })
	local no = UI.button({ Text = "NO THANKS", TextSize = 14, BackgroundColor3 = DIM, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), Size = UDim2.new(0.5, -4, 0, 34), ZIndex = 16, Parent = poseCard })
	yes.Activated:Connect(function()
		respondPose(true)
	end)
	no.Activated:Connect(function()
		respondPose(false)
	end)
end

local function showPoseRequest(fromUserId: number, fromName: string, emoteId: string)
	local Social = optionalClient("Social")
	if Social and Social.isBlocked and Social.isBlocked(fromUserId) then
		task.spawn(act, "poseRespond", fromUserId, false)
		return
	end
	local EmotesConfig = require(shared:WaitForChild("EmotesConfig"))
	local emote = EmotesConfig.find(emoteId)
	poseFrom = fromUserId
	poseToken += 1
	local token = poseToken
	poseText.Text = string.format("📸 %s wants a group photo: %s!", fromName, if emote then emote.name else emoteId)
	poseCard.Visible = true
	ContextActionService:BindAction("CGPoseAccept", function(_, state)
		if state == Enum.UserInputState.Begin then
			respondPose(true)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Y, Enum.KeyCode.ButtonY)
	task.delay(MediaConfig.POSE_REQUEST_SECONDS, function()
		if token == poseToken and poseCard.Visible then
			poseCard.Visible = false
			poseFrom = 0
			ContextActionService:UnbindAction("CGPoseAccept")
		end
	end)
end

---------------------------------------------------------------------------
-- Gallery app
---------------------------------------------------------------------------
local PAGE = 12
local galleryContent: ScrollingFrame
local galleryToken = 0
local galleryShown = PAGE
local galleryData: any = nil
local refreshGallery: () -> ()

local function openOwnPhoto(meta: any)
	local snap = Media.fetchPhoto(meta.id)
	if not snap then
		HUD.push("GALLERY", "That photo couldn't be loaded.")
		return
	end
	local isProfile = galleryData and galleryData.profile == meta.id
	local actions: { ViewerAction } = {}
	table.insert(actions, {
		label = if meta.vis == "public" then "🌐 PUBLIC" else "🔒 PRIVATE",
		color = if meta.vis == "public" then BLUE else DIM,
		fn = function()
			local ok, message = act("visibility", meta.id, if meta.vis == "public" then "private" else "public")
			if message then
				HUD.push("GALLERY", message)
			end
			if ok then
				meta.vis = if meta.vis == "public" then "private" else "public"
				openOwnPhoto(meta)
				refreshGallery()
			end
		end,
	})
	table.insert(actions, {
		label = if isProfile then "✓ PROFILE PIC" else "👤 SET PROFILE",
		color = if isProfile then GOOD else DIM,
		fn = function()
			local ok, message = act("profile", if isProfile then "" else meta.id)
			if message then
				HUD.push("GALLERY", message)
			end
			if ok then
				refreshGallery()
				task.delay(0.2, function()
					openOwnPhoto(meta)
				end)
			end
		end,
	})
	if deviceCaptures[meta.id] then
		table.insert(actions, {
			label = "💾 SAVE TO DEVICE",
			color = BLUE,
			fn = function()
				saveToDevice(meta.id)
			end,
		})
	end
	local armed = false
	table.insert(actions, {
		label = "🗑 DELETE",
		color = colors.danger,
		fn = function()
			if not armed then
				armed = true
				HUD.push("GALLERY", "Tap DELETE again to delete this photo.")
				task.delay(4, function()
					armed = false
				end)
				return
			end
			local ok, message = act("delete", meta.id)
			if message then
				HUD.push("GALLERY", message)
			end
			if ok then
				photoCache[meta.id] = nil
				closeViewer()
				refreshGallery()
			end
		end,
	})
	Media.openViewer({
		snap = snap,
		title = if meta.l and meta.l ~= "" then meta.l else "Photo",
		sub = describe(snap, UI.timeAgo(meta.t or 0)),
		actions = actions,
		input = {
			placeholder = "Caption... then POST to CityGram",
			button = "POST",
			max = MediaConfig.CAPTION_MAX,
			fn = function(text: string)
				local remotes = shared:FindFirstChild("Remotes")
				local remote = remotes and remotes:FindFirstChild("CityGramAction")
				if not remote or not remote:IsA("RemoteFunction") then
					HUD.push("CITYGRAM", "CityGram isn't available right now.")
					return
				end
				local okCall, ok, message = pcall(function()
					return (remote :: RemoteFunction):InvokeServer("post", meta.id, text)
				end)
				if not okCall then
					HUD.push("CITYGRAM", "Couldn't reach the server.")
					return
				end
				HUD.push(if ok then "CITYGRAM" else "CAN'T POST", tostring(message or (if ok then "Posted!" else "Try again.")))
				if ok then
					closeViewer()
					Phone.refresh("CityGram")
				end
			end,
		},
	})
end

local function thumbnail(parent: Instance, meta: any, order: number, token: number)
	local cell = UI.new("TextButton", { Text = "", AutoButtonColor = true, BackgroundColor3 = Color3.fromRGB(30, 30, 40), LayoutOrder = order, Parent = parent }, { UI.corner(8) })
	local vp = UI.new("ViewportFrame", { BackgroundColor3 = Color3.fromRGB(30, 30, 40), Size = UDim2.fromScale(1, 1), Active = false, Parent = cell }, { UI.corner(8) })
	local badge = ""
	if galleryData and galleryData.profile == meta.id then
		badge ..= "👤"
	end
	if meta.vis == "public" then
		badge ..= "🌐"
	end
	if badge ~= "" then
		UI.label({ Text = badge, TextSize = 12, Position = UDim2.fromOffset(3, 2), Size = UDim2.fromOffset(40, 14), ZIndex = 3, Parent = cell })
	end
	cell.Activated:Connect(function()
		openOwnPhoto(meta)
	end)
	-- lazy render: one thumbnail at a time while the gallery is on screen
	task.spawn(function()
		local snap = photoCache[meta.id]
		if not snap then
			task.wait(order * 0.12)
			if token ~= galleryToken or not cell.Parent then
				return
			end
			snap = Media.fetchPhoto(meta.id)
		end
		if snap and token == galleryToken and cell.Parent then
			Media.render(vp, snap, MediaConfig.THUMB_PARTS)
		end
	end)
end

refreshGallery = function()
	if not galleryContent then
		return
	end
	galleryToken += 1
	local token = galleryToken
	Phone.clear(galleryContent)
	local header = Phone.card(galleryContent, 86, 1)
	local count = UI.label({ Text = "Loading...", Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 20), Parent = header })
	UI.label({ Text = "Tap a photo to view, post or share it.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 16), Parent = header })
	local camButton = UI.button({ Text = "📷 OPEN CAMERA", TextSize = 13, BackgroundColor3 = colors.accent, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 30), Parent = header })
	camButton.Activated:Connect(Media.openCamera)

	local ok, message, data = act("list")
	if token ~= galleryToken then
		return
	end
	if not ok or type(data) ~= "table" then
		count.Text = message or "Gallery unavailable."
		return
	end
	galleryData = data
	count.Text = string.format("%d / %d photos", #data.photos, data.max or MediaConfig.MAX_PHOTOS)
	if #data.photos == 0 then
		local empty = Phone.card(galleryContent, 60, 2)
		UI.label({ Text = "No photos yet. Open the camera and snap the city!", TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.fromScale(1, 1), Parent = empty })
	else
		local grid = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = galleryContent }, {
			UI.new("UIGridLayout", { CellSize = UDim2.new(1 / 3, -4, 0, 70), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		for i = 1, math.min(#data.photos, galleryShown) do
			thumbnail(grid, data.photos[i], i, token)
		end
		if #data.photos > galleryShown then
			local more = UI.button({ Text = "SHOW MORE", TextSize = 13, Size = UDim2.new(1, -20, 0, 32), LayoutOrder = 3, Parent = galleryContent })
			more.Activated:Connect(function()
				galleryShown += PAGE
				refreshGallery()
			end)
		end
	end

	-- CityTok highlight clips, when that app exists
	task.spawn(function()
		local okClips, _, clips = act("clips")
		if token ~= galleryToken or not okClips or type(clips) ~= "table" or #clips == 0 then
			return
		end
		local card = Phone.card(galleryContent, 40 + math.min(#clips, 6) * 20, 4)
		UI.label({ Text = "🎬 CITYTOK HIGHLIGHTS", Font = UI.FONT_BLACK, TextSize = 13, Size = UDim2.new(1, -90, 0, 18), Parent = card })
		local open = UI.button({ Text = "OPEN", TextSize = 12, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(70, 22), Parent = card })
		open.Activated:Connect(function()
			Phone.showPage("CityTok")
		end)
		for i = 1, math.min(#clips, 6) do
			local c = clips[i]
			UI.label({ Text = tostring(c.title) .. (if (c.t or 0) > 0 then "  ·  " .. UI.timeAgo(c.t) else ""), TextSize = 12, TextColor3 = colors.subtext, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(0, 4 + i * 20), Size = UDim2.new(1, 0, 0, 18), Parent = card })
		end
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Media.start()
	Phone.addApp({ id = "Camera", label = "Camera", icon = "📷", color = CAMERA_COLOR }, function(content)
		local card = Phone.card(content, 120, 1)
		UI.label({ Text = "PHOTO MODE", Font = UI.FONT_BLACK, TextSize = 16, Size = UDim2.new(1, 0, 0, 20), Parent = card })
		UI.label({ Text = "Selfie, 1st / 3rd person, car shots, filters, poses and a timer.", TextSize = 12, TextWrapped = true, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 34), Parent = card })
		local open = UI.button({ Text = "📷 OPEN CAMERA", TextSize = 14, BackgroundColor3 = colors.accent, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 34), Parent = card })
		open.Activated:Connect(Media.openCamera)
		return function()
			-- opening the app goes straight into photo mode
			Media.openCamera()
		end
	end)
	Phone.addApp({ id = "Gallery", label = "Gallery", icon = "🖼️", color = GALLERY_COLOR }, function(content)
		galleryContent = content
		return function()
			galleryShown = PAGE
			refreshGallery()
		end
	end)

	task.spawn(function()
		gui = UI.new("ScreenGui", {
			Name = GUI_NAME,
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = 12,
			Parent = player:WaitForChild("PlayerGui"),
		})
		buildCameraUI(gui :: ScreenGui)
		buildViewer(gui :: ScreenGui)
		buildPoseCard(gui :: ScreenGui)

		local remotes = shared:WaitForChild("Remotes")
		MediaAction = remotes:WaitForChild("MediaAction") :: RemoteFunction
		local MediaEvent = remotes:WaitForChild("MediaEvent") :: RemoteEvent
		MediaEvent.OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any)
			if kind == "PoseRequest" and type(a) == "number" and type(b) == "string" and type(c) == "string" then
				showPoseRequest(a, b, c)
			end
		end)

		-- dying or respawning closes photo mode cleanly
		player.CharacterAdded:Connect(function()
			if cam.active then
				exitCamera()
			end
		end)
		while true do
			task.wait(1)
			if cam.active then
				refreshCarRow()
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if not humanoid or humanoid.Health <= 0 then
					exitCamera()
				end
			end
		end
	end)
end

return Media
