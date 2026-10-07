-- CITY GRIND: highlights + CityTok client (spec 22-25, 34, 37).
-- * "HIGHLIGHT SAVED" card with WATCH / EDIT / POST / DELETE when the server freezes a clip.
-- * Studio: fullscreen replay player + editor (trim handles, slow motion, camera, zoom,
--   text, filters, stickers, auto player/location tags, music if the Music module exists).
--   Editing only stores parameters; the server validates and filters them.
-- * Phone app "CityTok": vertical feed (tabs, swipe / wheel / buttons / L1-R1), likes,
--   comments, shares, favourites, follow, and a Library (my clips, posts, saved, inbox).
-- Clips are replay data rendered by shared/Replay in a ViewportFrame, never video files.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Cfg = require(shared:WaitForChild("CityTokConfig"))
local Replay = require(shared:WaitForChild("Replay"))

local player = Players.LocalPlayer
local colors = UI.colors
local PINK = Color3.fromRGB(240, 40, 110)
local CYAN = Color3.fromRGB(40, 220, 230)
local GOLD = Color3.fromRGB(255, 215, 70)
local SLOW = Color3.fromRGB(150, 90, 255)

local CityTok = {}

local Request: RemoteFunction? = nil
local caps = { follow = false, share = false }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function request(action: string, payload: any?): (boolean, string?, any)
	if not Request then
		return false, "CityTok is still loading.", nil
	end
	local ok, success, message, data = pcall(function()
		return (Request :: RemoteFunction):InvokeServer(action, payload)
	end)
	if not ok then
		return false, "Couldn't reach CityTok.", nil
	end
	return success == true, message, data
end

local function lazyModule(name: string): any
	local m = script.Parent:FindFirstChild(name)
	if not m or not m:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok and type(mod) == "table" then mod else nil
end

-- The in-game Music module, if it exists and exposes tracks() + preview(id).
local function music(): any
	local M = lazyModule("Music")
	if M and type(M.tracks) == "function" and type(M.preview) == "function" then
		return M
	end
	return nil
end

local function musicTracks(): { { id: string, name: string } }
	local M = music()
	if not M then
		return {}
	end
	local ok, list = pcall(M.tracks)
	local out = {}
	if ok and type(list) == "table" then
		for i, t in list do
			if type(t) == "table" then
				local id = t.id or t.Id or t.key or i
				local name = t.name or t.title or t.Name or tostring(id)
				local idText = tostring(id)
				if #idText <= 40 and idText:match("^[%w_%-]+$") then
					table.insert(out, { id = idText, name = tostring(name) })
				end
			end
		end
	end
	return out
end

local function trackName(id: string?): string?
	if not id then
		return nil
	end
	for _, t in musicTracks() do
		if t.id == id then
			return t.name
		end
	end
	return nil
end

local tokMusic = false -- true while a CityTok video's soundtrack is previewing
local function previewMusic(id: string?)
	local M = music()
	if M and id then
		tokMusic = true
		task.spawn(pcall, M.preview, id)
	end
end

local function stopMusic()
	local M = music()
	if tokMusic and M and type(M.stop) == "function" then
		pcall(M.stop)
	end
	tokMusic = false
end

local toastLabel: TextLabel? = nil
local toastToken = 0
local function toast(text: string?)
	if not text or text == "" or not toastLabel then
		return
	end
	toastToken += 1
	local token = toastToken
	local label = toastLabel :: TextLabel
	label.Text = text
	label.Visible = true
	task.delay(2.5, function()
		if toastToken == token then
			label.Visible = false
		end
	end)
end

local function countText(n: number?): string
	n = n or 0
	if (n :: number) >= 1000000 then
		return string.format("%.1fM", (n :: number) / 1000000)
	elseif (n :: number) >= 1000 then
		return string.format("%.1fK", (n :: number) / 1000)
	end
	return tostring(n)
end

local function defaultEdit(clip: any): any
	return { ts = 0, te = tonumber(clip.dur) or 0, fov = Cfg.FOV_DEFAULT, cam = "broadcast", fl = "none" }
end

local function copyEdit(edit: any): any
	local e = table.clone(edit)
	if e.sm then
		e.sm = table.clone(e.sm)
	end
	if e.st then
		local st = {}
		for i, s in e.st do
			st[i] = table.clone(s)
		end
		e.st = st
	end
	return e
end

local function focusName(clip: any): string
	for _, p in (type(clip.p) == "table" and clip.p or {}) do
		if p.u == clip.focus then
			return tostring(p.n)
		end
	end
	return "Player"
end

local function cameraName(kind: string?, mode: string): string
	local names = Cfg.CAMERA_NAMES[kind or ""] or Cfg.CAMERA_NAMES.default
	return names[mode] or mode
end

-- Two-tap confirm for destructive buttons.
local function confirmButton(button: TextButton, label: string, action: () -> ())
	local armed = false
	button.Text = label
	button.Activated:Connect(function()
		if armed then
			armed = false
			button.Text = label
			action()
			return
		end
		armed = true
		button.Text = "SURE?"
		task.delay(3, function()
			if armed then
				armed = false
				button.Text = label
			end
		end)
	end)
end

local function pill(props: { [string]: any }): TextButton
	local defaults = { TextSize = 13, Size = UDim2.fromOffset(70, 28), AutoButtonColor = true }
	for k, v in props do
		defaults[k] = v
	end
	return UI.button(defaults)
end

---------------------------------------------------------------------------
-- Stage: a ViewportFrame replay plus the edit overlays (text, stickers, filter, tags)
---------------------------------------------------------------------------
type Stage = {
	holder: Frame,
	viewport: ViewportFrame,
	replay: any,
	fx: Frame,
	tint: Frame,
	vignette: Frame,
	liveBug: Frame,
	text: TextLabel,
	stickerLayer: Frame,
	tagLabel: TextLabel,
	clip: any,
	edit: any,
	t: number,
	playing: boolean,
	active: boolean,
	snap: boolean,
	baseAmbient: Color3,
	baseLight: Color3,
	editable: boolean,
	onStickerMoved: ((number) -> ())?,
	onTime: ((number) -> ())?,
}

local stages: { [Stage]: boolean } = {}
local draggingSticker: { stage: Stage, index: number }? = nil

local function edgeGradient(parent: Instance, rotation: number, position: UDim2, size: UDim2)
	local f = UI.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), Position = position, Size = size, ZIndex = 5, Parent = parent })
	UI.new("UIGradient", { Rotation = rotation, Transparency = NumberSequence.new(0.15, 1), Parent = f })
end

local function newStage(parent: Instance, editable: boolean): Stage
	local holder = UI.new("Frame", {
		Name = "Stage",
		BackgroundColor3 = Color3.fromRGB(8, 8, 12),
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = parent,
	}, { UI.corner(12) })
	local viewport = UI.new("ViewportFrame", {
		BackgroundColor3 = Color3.fromRGB(135, 190, 240),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = holder,
	}, { UI.corner(12) })
	local fx = UI.new("Frame", { Name = "Fx", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = holder })
	local tint = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = fx })
	local vignette = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Visible = false, Parent = fx })
	edgeGradient(vignette, 90, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.25))
	edgeGradient(vignette, -90, UDim2.fromScale(0, 0.75), UDim2.fromScale(1, 0.25))
	edgeGradient(vignette, 0, UDim2.fromScale(0, 0), UDim2.fromScale(0.22, 1))
	edgeGradient(vignette, 180, UDim2.fromScale(0.78, 0), UDim2.fromScale(0.22, 1))
	local liveBug = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 6, Visible = false, Parent = fx })
	UI.label({ Text = "● LIVE", Font = UI.FONT_BLACK, TextScaled = true, TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(220, 30, 40), Position = UDim2.fromScale(0.04, 0.04), Size = UDim2.fromScale(0.18, 0.06), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 6, Parent = liveBug }, { UI.corner(4) })
	UI.label({ Text = "CITY GRIND SPORTS", Font = UI.FONT_BLACK, TextScaled = true, BackgroundTransparency = 0.15, BackgroundColor3 = Color3.fromRGB(15, 20, 60), Position = UDim2.fromScale(0, 0.9), Size = UDim2.fromScale(1, 0.06), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 6, Parent = liveBug })
	local text = UI.label({
		Name = "OverlayText",
		Font = UI.FONT_BLACK,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.8),
		Size = UDim2.fromScale(0.92, 0.1),
		Visible = false,
		ZIndex = 7,
		Parent = fx,
	})
	local stickerLayer = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 8, Parent = fx })
	local tagLabel = UI.label({
		Font = UI.FONT_BOLD,
		TextScaled = true,
		TextStrokeTransparency = 0.3,
		Position = UDim2.fromScale(0.03, 0.02),
		Size = UDim2.fromScale(0.94, 0.045),
		ZIndex = 7,
		Parent = fx,
	})
	local stage: Stage = {
		holder = holder,
		viewport = viewport,
		replay = Replay.new(viewport),
		fx = fx,
		tint = tint,
		vignette = vignette,
		liveBug = liveBug,
		text = text,
		stickerLayer = stickerLayer,
		tagLabel = tagLabel,
		clip = nil,
		edit = nil,
		t = 0,
		playing = true,
		active = false,
		snap = true,
		baseAmbient = viewport.Ambient,
		baseLight = viewport.LightColor,
		editable = editable,
		onStickerMoved = nil,
		onTime = nil,
	}
	stages[stage] = true
	return stage
end

local function stageRate(stage: Stage): number
	local sm = stage.edit and stage.edit.sm
	if sm and stage.t >= sm[1] and stage.t <= sm[2] then
		return sm[3]
	end
	return 1
end

local function drawStickers(stage: Stage)
	for _, child in stage.stickerLayer:GetChildren() do
		child:Destroy()
	end
	for i, s in (stage.edit and stage.edit.st or {}) do
		local sticker = UI.new("TextButton", {
			Text = Cfg.STICKERS[s.e] or "",
			TextScaled = true,
			Font = UI.FONT,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Active = stage.editable,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(s.x, s.y),
			Size = UDim2.fromScale(0.14, 0.14),
			ZIndex = 9,
			Parent = stage.stickerLayer,
		}, { UI.new("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Height }) })
		if stage.editable then
			sticker.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					draggingSticker = { stage = stage, index = i }
				end
			end)
		end
	end
end

local function applyEdit(stage: Stage, edit: any)
	stage.edit = edit
	local clip = stage.clip
	if not clip then
		return
	end
	stage.replay:setCamera(edit.cam or "broadcast", edit.fov or Cfg.FOV_DEFAULT)
	local f = Cfg.FILTER_BY_ID[edit.fl or "none"] or Cfg.FILTERS[1]
	stage.viewport.ImageColor3 = f.tint or Color3.new(1, 1, 1)
	stage.viewport.Ambient = f.ambient or stage.baseAmbient
	stage.viewport.LightColor = f.light or stage.baseLight
	stage.tint.BackgroundColor3 = f.overlay or Color3.new(0, 0, 0)
	stage.tint.BackgroundTransparency = if f.overlay then f.overlayAlpha or 0.85 else 1
	stage.vignette.Visible = f.vignette == true
	stage.liveBug.Visible = f.broadcastBug == true
	local tx = edit.tx
	stage.text.Visible = type(tx) == "string" and tx ~= ""
	stage.text.Text = if type(tx) == "string" then tx else ""
	stage.text.Position = UDim2.fromScale(0.5, edit.ty or 0.8)
	stage.tagLabel.Text = "👤 " .. focusName(clip) .. "   📍 " .. tostring(clip.loc or "The Neighborhood")
	drawStickers(stage)
	stage.snap = true
end

local function loadStage(stage: Stage, clip: any, edit: any?)
	stage.clip = clip
	stage.replay:load(clip)
	stage.baseAmbient = stage.viewport.Ambient
	stage.baseLight = stage.viewport.LightColor
	local e = edit or defaultEdit(clip)
	applyEdit(stage, e)
	stage.t = e.ts or 0
	stage.snap = true
	stage.replay:render(stage.t, 0, true)
end

local function seekStage(stage: Stage, t: number)
	if not stage.clip then
		return
	end
	stage.t = math.clamp(t, 0, tonumber(stage.clip.dur) or 0)
	stage.snap = true
end

local function destroyStage(stage: Stage)
	stages[stage] = nil
	stage.replay:destroy()
	stage.holder:Destroy()
end

-- One loop drives every visible stage.
RunService.RenderStepped:Connect(function(dt)
	for stage in stages do
		if stage.active and stage.clip then
			local edit = stage.edit
			local ts = edit and edit.ts or 0
			local te = edit and edit.te or tonumber(stage.clip.dur) or 0
			if stage.playing then
				stage.t += dt * stageRate(stage)
				if stage.t > te or stage.t < ts - 0.01 then
					stage.t = ts
					stage.snap = true
				end
			end
			stage.replay:render(stage.t, dt, stage.snap)
			stage.snap = false
			if stage.onTime then
				stage.onTime(stage.t)
			end
		end
	end
end)

-- Sticker dragging (studio).
UserInputService.InputChanged:Connect(function(input)
	local drag = draggingSticker
	if not drag then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local layer = drag.stage.stickerLayer
	local pos, size = layer.AbsolutePosition, layer.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	local s = drag.stage.edit.st and drag.stage.edit.st[drag.index]
	if s then
		s.x = math.clamp((input.Position.X - pos.X) / size.X, 0, 1)
		s.y = math.clamp((input.Position.Y - pos.Y) / size.Y, 0, 1)
		local child = layer:GetChildren()[drag.index]
		if child and child:IsA("GuiObject") then
			child.Position = UDim2.fromScale(s.x, s.y)
		end
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if draggingSticker and draggingSticker.stage.onStickerMoved then
			(draggingSticker.stage.onStickerMoved :: (number) -> ())(draggingSticker.index)
		end
		draggingSticker = nil
	end
end)

---------------------------------------------------------------------------
-- Studio: fullscreen player / editor for your own clips
---------------------------------------------------------------------------
local studioGui: ScreenGui
local studio = {
	open = false,
	editing = false,
	clip = nil :: any,
	edit = nil :: any,
	stage = nil :: Stage?,
}
local studioRefs: { [string]: any } = {}
local libraryRefresh: (() -> ())? = nil
local openPostSheet: () -> ()

local function setButtonOn(button: TextButton, on: boolean, color: Color3?)
	button.BackgroundColor3 = if on then (color or PINK) else colors.panelLight
end

local function closeStudio()
	studio.open = false
	stopMusic()
	if studio.stage then
		destroyStage(studio.stage)
		studio.stage = nil
	end
	studioGui.Enabled = false
	studio.clip = nil
	if libraryRefresh then
		libraryRefresh()
	end
end

local function sectionLabel(parent: Instance, text: string, order: number)
	UI.label({ Text = text, Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = order, Parent = parent })
end

local function row(parent: Instance, order: number, height: number?): Frame
	return UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height or 30), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Wraps = true }),
	})
end

-- Timeline: trim handles, slow-mo band and playhead. Dragging uses the shared input listeners.
local timelineDrag: string? = nil
local function timelineFraction(x: number): number
	local bar = studioRefs.bar :: Frame
	return math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
end

local function refreshTimeline()
	local clip, edit = studio.clip, studio.edit
	if not clip or not edit then
		return
	end
	local dur = math.max(0.01, tonumber(clip.dur) or 0.01)
	studioRefs.trim.Position = UDim2.fromScale(edit.ts / dur, 0)
	studioRefs.trim.Size = UDim2.fromScale((edit.te - edit.ts) / dur, 1)
	studioRefs.startHandle.Position = UDim2.new(edit.ts / dur, 0, 0.5, 0)
	studioRefs.endHandle.Position = UDim2.new(edit.te / dur, 0, 0.5, 0)
	if edit.sm then
		studioRefs.slowBand.Visible = true
		studioRefs.slowBand.Position = UDim2.fromScale(edit.sm[1] / dur, 0.62)
		studioRefs.slowBand.Size = UDim2.fromScale((edit.sm[2] - edit.sm[1]) / dur, 0.38)
	else
		studioRefs.slowBand.Visible = false
	end
	studioRefs.trimLabel.Text = string.format("Trim %.1fs – %.1fs  (%.1fs)", edit.ts, edit.te, edit.te - edit.ts)
	studioRefs.slowLabel.Text = if edit.sm then string.format("Slow-mo %.1fs – %.1fs at %sx", edit.sm[1], edit.sm[2], tostring(edit.sm[3])) else "Slow-mo off"
	for rate, b in studioRefs.slowButtons do
		setButtonOn(b, (edit.sm and edit.sm[3] or 0) == rate, SLOW)
	end
end

local function refreshEditControls()
	local edit, clip = studio.edit, studio.clip
	if not edit or not clip then
		return
	end
	for mode, b in studioRefs.camButtons do
		setButtonOn(b, edit.cam == mode)
		b.Text = cameraName(clip.kind, mode)
	end
	for id, b in studioRefs.filterButtons do
		setButtonOn(b, edit.fl == id, CYAN)
	end
	for y, b in studioRefs.textPosButtons do
		setButtonOn(b, math.abs((edit.ty or 0.8) - y) < 0.05, CYAN)
	end
	if studioRefs.musicButtons then
		for id, b in studioRefs.musicButtons do
			setButtonOn(b, (edit.mu or "") == id, GOLD)
		end
	end
	studioRefs.fovLabel.Text = "Zoom  " .. tostring(edit.fov or Cfg.FOV_DEFAULT) .. "°"
	studioRefs.fovFill.Size = UDim2.fromScale(1 - ((edit.fov or Cfg.FOV_DEFAULT) - Cfg.FOV_MIN) / (Cfg.FOV_MAX - Cfg.FOV_MIN), 1)
	if not studioRefs.textBox:IsFocused() then
		studioRefs.textBox.Text = edit.tx or ""
	end
	studioRefs.stickerCount.Text = string.format("%d / %d placed · drag them on the video", edit.st and #edit.st or 0, Cfg.MAX_STICKERS)
	refreshTimeline()
end

local function editChanged()
	if studio.stage then
		applyEdit(studio.stage, studio.edit)
	end
	refreshEditControls()
end

local function layoutStudio()
	local camera = Workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local main = studioRefs.main :: Frame
	local left = studioRefs.left :: Frame
	local right = studioRefs.right :: Frame
	if size.X >= size.Y * 1.15 then
		main.Size = UDim2.fromScale(0.96, 0.92)
		left.Size = UDim2.fromScale(0.62, 1)
		right.Position = UDim2.fromScale(0.635, 0)
		right.Size = UDim2.fromScale(0.365, 1)
	else
		main.Size = UDim2.fromScale(0.96, 0.94)
		left.Size = UDim2.fromScale(1, 0.48)
		right.Position = UDim2.fromScale(0, 0.5)
		right.Size = UDim2.fromScale(1, 0.5)
	end
end

local function buildStudio()
	studioGui = UI.new("ScreenGui", {
		Name = "CityTokStudio",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 9,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	-- Modal backdrop frees the mouse while editing.
	UI.new("TextButton", { Text = "", AutoButtonColor = false, Modal = true, BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1), Parent = studioGui })
	local main = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.96, 0.92),
		Parent = studioGui,
	}, { UI.corner(16), UI.padding(10), UI.stroke(PINK, 1.5, 0.4) })
	studioRefs.main = main

	-- left: video + timeline
	local left = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0.62, 1), Parent = main })
	studioRefs.left = left
	studioRefs.title = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = PINK, Size = UDim2.new(1, 0, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd, Parent = left })
	local videoArea = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 1, -112), Parent = left })
	local video = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = videoArea }, {
		UI.new("UIAspectRatioConstraint", { AspectRatio = 16 / 9 }),
	})
	studioRefs.video = video

	local controls = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 82), Parent = left })
	local playButton = UI.button({ Text = "❚❚", TextSize = 16, BackgroundColor3 = PINK, Size = UDim2.fromOffset(44, 32), Parent = controls })
	studioRefs.playButton = playButton
	playButton.Activated:Connect(function()
		local stage = studio.stage
		if stage then
			stage.playing = not stage.playing
			playButton.Text = if stage.playing then "❚❚" else "▶"
		end
	end)
	studioRefs.timeLabel = UI.label({ Text = "0.0s", Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(52, 0), Size = UDim2.fromOffset(110, 32), Parent = controls })
	studioRefs.trimLabel = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(160, 0), Size = UDim2.new(1, -160, 0, 16), TextXAlignment = Enum.TextXAlignment.Right, Parent = controls })
	studioRefs.slowLabel = UI.label({ Text = "", TextSize = 12, TextColor3 = SLOW, Position = UDim2.fromOffset(160, 16), Size = UDim2.new(1, -160, 0, 16), TextXAlignment = Enum.TextXAlignment.Right, Parent = controls })

	local bar = UI.new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromRGB(45, 45, 58), Position = UDim2.new(0, 10, 0, 44), Size = UDim2.new(1, -20, 0, 26), Parent = controls }, { UI.corner(6) })
	studioRefs.bar = bar
	studioRefs.trim = UI.new("Frame", { BackgroundColor3 = PINK, BackgroundTransparency = 0.55, Size = UDim2.fromScale(1, 1), Parent = bar }, { UI.corner(6) })
	studioRefs.slowBand = UI.new("Frame", { BackgroundColor3 = SLOW, BackgroundTransparency = 0.1, Visible = false, Parent = bar }, { UI.corner(3) })
	local playhead = UI.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.new(0, 3, 1, 8), Position = UDim2.new(0, 0, 0, -4), ZIndex = 3, Parent = bar })
	studioRefs.playhead = playhead
	local function handle(name: string): TextButton
		local h = UI.new("TextButton", {
			Name = name,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = Color3.new(1, 1, 1),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(14, 36),
			ZIndex = 4,
			Parent = bar,
		}, { UI.corner(4), UI.stroke(PINK, 2) })
		h.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				timelineDrag = name
			end
		end)
		return h
	end
	studioRefs.startHandle = handle("start")
	studioRefs.endHandle = handle("end")
	bar.InputBegan:Connect(function(input)
		if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and not timelineDrag then
			timelineDrag = "seek"
			local stage = studio.stage
			if stage and studio.clip then
				seekStage(stage, timelineFraction(input.Position.X) * (tonumber(studio.clip.dur) or 0))
			end
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not timelineDrag or not studio.open then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local dur = tonumber(studio.clip and studio.clip.dur) or 0
		local t = timelineFraction(input.Position.X) * dur
		local edit = studio.edit
		if timelineDrag == "start" and studio.editing then
			edit.ts = math.clamp(t, 0, edit.te - 1)
			if edit.sm then
				edit.sm[1] = math.max(edit.sm[1], edit.ts)
				if edit.sm[2] - edit.sm[1] < 0.2 then
					edit.sm = nil
				end
			end
			if studio.stage then
				seekStage(studio.stage, edit.ts)
			end
			refreshTimeline()
		elseif timelineDrag == "end" and studio.editing then
			edit.te = math.clamp(t, edit.ts + 1, dur)
			if edit.sm then
				edit.sm[2] = math.min(edit.sm[2], edit.te)
				if edit.sm[2] - edit.sm[1] < 0.2 then
					edit.sm = nil
				end
			end
			refreshTimeline()
		elseif timelineDrag == "seek" and studio.stage then
			seekStage(studio.stage, t)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if timelineDrag == "start" or timelineDrag == "end" then
				editChanged()
			end
			timelineDrag = nil
		end
	end)

	-- right: controls
	local right = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.635, 0),
		Size = UDim2.fromScale(0.365, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = main,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		UI.new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10) }),
	})
	studioRefs.right = right
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	studioRefs.tags = UI.label({ Text = "", TextSize = 13, TextWrapped = true, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = nextOrder(), Parent = right })
	local editOnly: { GuiObject } = {}
	local function editSection(obj: GuiObject): GuiObject
		table.insert(editOnly, obj)
		return obj
	end
	studioRefs.editOnly = editOnly
	table.insert(editOnly, studioRefs.startHandle)
	table.insert(editOnly, studioRefs.endHandle)

	-- camera (also usable while just watching)
	sectionLabel(right, "CAMERA", nextOrder())
	local camRow = row(right, nextOrder())
	studioRefs.camButtons = {}
	for _, mode in Cfg.CAMERAS do
		local b = pill({ Text = mode, Size = UDim2.fromOffset(96, 28), Parent = camRow })
		studioRefs.camButtons[mode] = b
		b.Activated:Connect(function()
			studio.edit.cam = mode
			editChanged()
		end)
	end

	-- zoom slider
	studioRefs.fovLabel = UI.label({ Text = "Zoom", Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right })
	local zoomRow = row(right, nextOrder())
	local minus = pill({ Text = "−", Size = UDim2.fromOffset(32, 28), Parent = zoomRow })
	local slider = UI.new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromRGB(45, 45, 58), Size = UDim2.new(1, -90, 0, 28), Parent = zoomRow }, { UI.corner(8) })
	studioRefs.fovFill = UI.new("Frame", { BackgroundColor3 = CYAN, Size = UDim2.fromScale(0.5, 1), Parent = slider }, { UI.corner(8) })
	local plus = pill({ Text = "+", Size = UDim2.fromOffset(32, 28), Parent = zoomRow })
	local function setFov(fov: number)
		studio.edit.fov = math.floor(math.clamp(fov, Cfg.FOV_MIN, Cfg.FOV_MAX) + 0.5)
		editChanged()
	end
	minus.Activated:Connect(function()
		setFov((studio.edit.fov or Cfg.FOV_DEFAULT) + 5)
	end)
	plus.Activated:Connect(function()
		setFov((studio.edit.fov or Cfg.FOV_DEFAULT) - 5)
	end)
	local sliding = false
	local function slideTo(x: number)
		local f = math.clamp((x - slider.AbsolutePosition.X) / math.max(1, slider.AbsoluteSize.X), 0, 1)
		setFov(Cfg.FOV_MAX - f * (Cfg.FOV_MAX - Cfg.FOV_MIN))
	end
	slider.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding = true
			slideTo(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			slideTo(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			sliding = false
		end
	end)

	-- trim
	local function playheadTime(): number
		return if studio.stage then studio.stage.t else 0
	end
	editSection(UI.label({ Text = "TRIM  ·  drag the white handles", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right }))
	local trimRow = editSection(row(right, nextOrder()))
	local trimStart = pill({ Text = "Start here", Size = UDim2.fromOffset(92, 28), Parent = trimRow })
	local trimEnd = pill({ Text = "End here", Size = UDim2.fromOffset(92, 28), Parent = trimRow })
	local trimReset = pill({ Text = "Reset", Size = UDim2.fromOffset(64, 28), Parent = trimRow })
	trimStart.Activated:Connect(function()
		local e = studio.edit
		e.ts = math.clamp(playheadTime(), 0, e.te - 1)
		if e.sm and e.sm[1] < e.ts then
			e.sm = nil
		end
		editChanged()
	end)
	trimEnd.Activated:Connect(function()
		local e = studio.edit
		e.te = math.clamp(playheadTime(), e.ts + 1, tonumber(studio.clip.dur) or 0)
		if e.sm and e.sm[2] > e.te then
			e.sm = nil
		end
		editChanged()
	end)
	trimReset.Activated:Connect(function()
		studio.edit.ts, studio.edit.te, studio.edit.sm = 0, tonumber(studio.clip.dur) or 0, nil
		editChanged()
	end)

	-- slow motion
	editSection(UI.label({ Text = "SLOW MOTION", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right }))
	local slowRow = editSection(row(right, nextOrder()))
	studioRefs.slowButtons = {}
	local off = pill({ Text = "Off", Size = UDim2.fromOffset(52, 28), Parent = slowRow })
	studioRefs.slowButtons[0] = off
	off.Activated:Connect(function()
		studio.edit.sm = nil
		editChanged()
	end)
	for _, rate in Cfg.SLOWMO_RATES do
		local b = pill({ Text = tostring(rate) .. "x", Size = UDim2.fromOffset(58, 28), Parent = slowRow })
		studioRefs.slowButtons[rate] = b
		b.Activated:Connect(function()
			local e = studio.edit
			if e.sm then
				e.sm[3] = rate
			else
				local t = playheadTime()
				local a = math.clamp(t - 0.75, e.ts, e.te)
				local bEnd = math.clamp(t + 0.75, a, e.te)
				if bEnd - a < 0.2 then
					a, bEnd = e.ts, math.min(e.te, e.ts + 1.5)
				end
				e.sm = { a, bEnd, rate }
			end
			editChanged()
		end)
	end
	local slowRow2 = editSection(row(right, nextOrder()))
	local slowIn = pill({ Text = "Slow from here", Size = UDim2.fromOffset(112, 28), Parent = slowRow2 })
	local slowOut = pill({ Text = "Slow to here", Size = UDim2.fromOffset(104, 28), Parent = slowRow2 })
	slowIn.Activated:Connect(function()
		local e = studio.edit
		local t = math.clamp(playheadTime(), e.ts, e.te)
		local rate = e.sm and e.sm[3] or 0.5
		local bEnd = e.sm and e.sm[2] or math.min(e.te, t + 1.5)
		if bEnd - t >= 0.2 then
			e.sm = { t, bEnd, rate }
		end
		editChanged()
	end)
	slowOut.Activated:Connect(function()
		local e = studio.edit
		local t = math.clamp(playheadTime(), e.ts, e.te)
		local rate = e.sm and e.sm[3] or 0.5
		local a = e.sm and e.sm[1] or math.max(e.ts, t - 1.5)
		if t - a >= 0.2 then
			e.sm = { a, t, rate }
		end
		editChanged()
	end)

	-- text overlay
	editSection(UI.label({ Text = "TEXT", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right }))
	local textBox = editSection(UI.new("TextBox", {
		Text = "",
		PlaceholderText = "Text on the video (filtered when saved)",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = nextOrder(),
		Parent = right,
	}, { UI.corner(8), UI.padding(6) })) :: TextBox
	studioRefs.textBox = textBox
	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		if utf8.len(textBox.Text) and (utf8.len(textBox.Text) :: number) > Cfg.OVERLAY_MAX then
			textBox.Text = textBox.Text:sub(1, (utf8.offset(textBox.Text, Cfg.OVERLAY_MAX + 1) :: number) - 1)
		end
	end)
	textBox.FocusLost:Connect(function()
		if studio.edit then
			studio.edit.tx = if textBox.Text ~= "" then textBox.Text else nil
			editChanged()
		end
	end)
	local textRow = editSection(row(right, nextOrder()))
	studioRefs.textPosButtons = {}
	for _, pos in { { "Top", 0.12 }, { "Middle", 0.5 }, { "Bottom", 0.8 } } do
		local b = pill({ Text = pos[1], Size = UDim2.fromOffset(70, 28), Parent = textRow })
		studioRefs.textPosButtons[pos[2]] = b
		b.Activated:Connect(function()
			studio.edit.ty = pos[2]
			editChanged()
		end)
	end

	-- filters
	editSection(UI.label({ Text = "FILTER", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right }))
	local filterRow = editSection(row(right, nextOrder(), 64))
	studioRefs.filterButtons = {}
	for _, f in Cfg.FILTERS do
		local b = pill({ Text = f.name, TextSize = 12, Size = UDim2.fromOffset(84, 28), Parent = filterRow })
		studioRefs.filterButtons[f.id] = b
		b.Activated:Connect(function()
			studio.edit.fl = f.id
			editChanged()
		end)
	end

	-- stickers
	editSection(UI.label({ Text = "STICKERS", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right }))
	local stickerRow = editSection(row(right, nextOrder(), 64))
	for i, emoji in Cfg.STICKERS do
		local b = pill({ Text = emoji, TextSize = 18, Font = UI.FONT, Size = UDim2.fromOffset(32, 28), Parent = stickerRow })
		b.Activated:Connect(function()
			local e = studio.edit
			e.st = e.st or {}
			if #e.st >= Cfg.MAX_STICKERS then
				toast("Up to " .. Cfg.MAX_STICKERS .. " stickers.")
				return
			end
			table.insert(e.st, { e = i, x = 0.3 + 0.08 * #e.st, y = 0.35 })
			editChanged()
		end)
	end
	studioRefs.stickerCount = editSection(UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = nextOrder(), Parent = right }))
	local stickerRow2 = editSection(row(right, nextOrder()))
	local undoSticker = pill({ Text = "Remove last", Size = UDim2.fromOffset(100, 28), Parent = stickerRow2 })
	local clearStickers = pill({ Text = "Clear all", Size = UDim2.fromOffset(84, 28), Parent = stickerRow2 })
	undoSticker.Activated:Connect(function()
		local e = studio.edit
		if e.st and #e.st > 0 then
			table.remove(e.st)
			if #e.st == 0 then
				e.st = nil
			end
			editChanged()
		end
	end)
	clearStickers.Activated:Connect(function()
		studio.edit.st = nil
		editChanged()
	end)

	-- music: only when the game's Music module exists (no fake option otherwise)
	local tracks = musicTracks()
	if #tracks > 0 then
		editSection(UI.label({ Text = "MUSIC", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = nextOrder(), Parent = right }))
		local musicRow = editSection(row(right, nextOrder(), 30 + 34 * math.ceil(#tracks / 2)))
		studioRefs.musicButtons = {}
		local none = pill({ Text = "No music", TextSize = 12, Size = UDim2.fromOffset(120, 28), Parent = musicRow })
		studioRefs.musicButtons[""] = none
		none.Activated:Connect(function()
			studio.edit.mu = nil
			editChanged()
		end)
		for _, t in tracks do
			local b = pill({ Text = "♪ " .. t.name, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.fromOffset(120, 28), Parent = musicRow })
			studioRefs.musicButtons[t.id] = b
			b.Activated:Connect(function()
				studio.edit.mu = t.id
				previewMusic(t.id)
				editChanged()
			end)
		end
	end

	-- actions
	local actions = row(right, nextOrder(), 72)
	local editButton = pill({ Text = "EDIT", BackgroundColor3 = CYAN, TextColor3 = Color3.new(0, 0, 0), Size = UDim2.fromOffset(78, 32), Parent = actions })
	local saveButton = pill({ Text = "SAVE", BackgroundColor3 = CYAN, TextColor3 = Color3.new(0, 0, 0), Size = UDim2.fromOffset(78, 32), Parent = actions })
	local postButton = pill({ Text = "POST", BackgroundColor3 = PINK, Size = UDim2.fromOffset(78, 32), Parent = actions })
	local deleteButton = pill({ Text = "DELETE", BackgroundColor3 = Color3.fromRGB(120, 35, 40), Size = UDim2.fromOffset(78, 32), Parent = actions })
	local closeButton = pill({ Text = "CLOSE", Size = UDim2.fromOffset(78, 32), Parent = actions })
	studioRefs.editButton, studioRefs.saveButton, studioRefs.postButton = editButton, saveButton, postButton
	editButton.Activated:Connect(function()
		studio.editing = true
		for _, obj in editOnly do
			obj.Visible = true
		end
		editButton.Visible = false
		saveButton.Visible = true
	end)
	saveButton.Activated:Connect(function()
		if not studio.clip then
			return
		end
		saveButton.Text = "..."
		local ok, msg, edit = request("SaveEdit", { id = studio.clip.id, edit = studio.edit })
		saveButton.Text = "SAVE"
		toast(msg)
		if ok and type(edit) == "table" then
			studio.edit = edit
			studio.clip.edit = copyEdit(edit)
			editChanged()
		end
	end)
	postButton.Activated:Connect(function()
		openPostSheet()
	end)
	confirmButton(deleteButton, "DELETE", function()
		if not studio.clip then
			return
		end
		local ok, msg = request("DeleteClip", studio.clip.id)
		toast(msg)
		if ok then
			closeStudio()
		end
	end)
	closeButton.Activated:Connect(closeStudio)

	-- post sheet
	local sheet = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(360, 300),
		Visible = false,
		ZIndex = 20,
		Parent = studioGui,
	}, { UI.corner(16), UI.padding(14), UI.stroke(PINK, 2) })
	studioRefs.sheet = sheet
	UI.label({ Text = "POST TO CITYTOK", Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = PINK, Size = UDim2.new(1, 0, 0, 22), ZIndex = 20, Parent = sheet })
	local caption = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "Caption (optional, filtered)",
		ClearTextOnFocus = false,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = UI.FONT,
		TextSize = 14,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		BackgroundColor3 = colors.panelLight,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 64),
		ZIndex = 20,
		Parent = sheet,
	}, { UI.corner(8), UI.padding(6) }) :: TextBox
	studioRefs.caption = caption
	caption:GetPropertyChangedSignal("Text"):Connect(function()
		local len = utf8.len(caption.Text)
		if len and len > Cfg.CAPTION_MAX then
			caption.Text = caption.Text:sub(1, (utf8.offset(caption.Text, Cfg.CAPTION_MAX + 1) :: number) - 1)
		end
	end)
	UI.label({ Text = "CATEGORY", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 100), Size = UDim2.new(1, 0, 0, 14), ZIndex = 20, Parent = sheet })
	local catGrid = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 118), Size = UDim2.new(1, 0, 0, 100), ZIndex = 20, Parent = sheet }, {
		UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(104, 28), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	studioRefs.catButtons = {}
	for i, cat in Cfg.CATEGORIES do
		local b = pill({ Text = cat, TextSize = 12, LayoutOrder = i, ZIndex = 20, Parent = catGrid })
		studioRefs.catButtons[cat] = b
		b.Activated:Connect(function()
			studioRefs.category = cat
			for c, other in studioRefs.catButtons do
				setButtonOn(other, c == cat)
			end
		end)
	end
	local postNow = pill({ Text = "POST", BackgroundColor3 = PINK, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(0.48, 0, 0, 36), ZIndex = 20, Parent = sheet })
	local cancel = pill({ Text = "Cancel", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.new(0.48, 0, 0, 36), ZIndex = 20, Parent = sheet })
	cancel.Activated:Connect(function()
		sheet.Visible = false
	end)
	postNow.Activated:Connect(function()
		if not studio.clip then
			return
		end
		postNow.Text = "POSTING..."
		local ok, msg = request("Post", { id = studio.clip.id, cap = caption.Text, cat = studioRefs.category, edit = studio.edit })
		postNow.Text = "POST"
		toast(msg)
		if ok then
			sheet.Visible = false
			studio.clip.posted = true
			postButton.Visible = false
		end
	end)

	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if studio.open then
				layoutStudio()
			end
		end)
	end
end

openPostSheet = function()
	local clip = studio.clip
	if not clip or clip.posted then
		toast("This clip is already posted.")
		return
	end
	local sheet = studioRefs.sheet :: Frame
	studioRefs.caption.Text = ""
	local cat = Cfg.KIND_CATEGORY[clip.kind] or "City Life"
	studioRefs.category = cat
	for c, b in studioRefs.catButtons do
		setButtonOn(b, c == cat)
	end
	sheet.Visible = true
end

-- Opens one of your clips: mode "watch", "edit" or "post".
local function openStudio(clipId: string, mode: string)
	if not studioGui then
		toast("CityTok is still loading.")
		return
	end
	local ok, msg, clip = request("GetClip", clipId)
	if not ok or type(clip) ~= "table" then
		toast(msg or "That clip is gone.")
		return
	end
	if studio.stage then
		destroyStage(studio.stage)
		studio.stage = nil
	end
	studio.open = true
	studio.clip = clip
	studio.edit = if type(clip.edit) == "table" then copyEdit(clip.edit) else defaultEdit(clip)
	studio.editing = mode == "edit"
	studioGui.Enabled = true
	layoutStudio()
	studioRefs.title.Text = (Cfg.KIND_ICON[clip.kind] or "🎬") .. "  " .. tostring(clip.title or "CLIP")
	studioRefs.tags.Text = string.format("👤 %s   📍 %s   ·   %d in clip   ·   %s", focusName(clip), tostring(clip.loc or ""), type(clip.p) == "table" and #clip.p or 0, UI.timeAgo(tonumber(clip.at) or os.time()))
	for _, obj in studioRefs.editOnly do
		obj.Visible = studio.editing
	end
	studioRefs.editButton.Visible = not studio.editing
	studioRefs.saveButton.Visible = studio.editing
	studioRefs.postButton.Visible = not clip.posted
	studioRefs.sheet.Visible = false
	studioRefs.playButton.Text = "❚❚"

	local stage = newStage(studioRefs.video, true)
	studio.stage = stage
	loadStage(stage, clip, studio.edit)
	stage.edit = studio.edit
	stage.active = true
	stage.onStickerMoved = function()
		refreshEditControls()
	end
	stage.onTime = function(t)
		local dur = math.max(0.01, tonumber(clip.dur) or 0.01)
		studioRefs.playhead.Position = UDim2.new(t / dur, 0, 0, -4)
		studioRefs.timeLabel.Text = string.format("%.1fs / %.1fs%s", t, dur, if stageRate(stage) < 1 then "  SLOW" else "")
	end
	previewMusic(studio.edit.mu)
	refreshEditControls()
	if mode == "post" then
		openPostSheet()
	end
end

---------------------------------------------------------------------------
-- "HIGHLIGHT SAVED" card (spec 34)
---------------------------------------------------------------------------
local cardGui: ScreenGui
local cardToken = 0

local function showHighlight(summary: any)
	if type(summary) ~= "table" or type(summary.id) ~= "string" then
		return
	end
	cardToken += 1
	local token = cardToken
	cardGui:ClearAllChildren()
	local card = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.05,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.fromOffset(340, 104),
		Parent = cardGui,
	}, { UI.corner(14), UI.stroke(PINK, 2), UI.padding(10) })
	UI.label({ Text = "🎬 HIGHLIGHT SAVED", Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = PINK, Size = UDim2.new(1, -30, 0, 18), Parent = card })
	UI.label({
		Text = string.format("%s %s  ·  %s", Cfg.KIND_ICON[summary.kind] or "", tostring(summary.title or "CLIP"), tostring(summary.loc or "")),
		Font = UI.FONT_BOLD,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = card,
	})
	local close = UI.button({ Text = "✕", TextSize = 14, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(26, 22), Parent = card })
	close.Activated:Connect(function()
		card:Destroy()
	end)
	local buttons = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 34), Parent = card }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local function action(text: string, color: Color3, order: number, fn: () -> ())
		local b = UI.button({ Text = text, TextSize = 13, BackgroundColor3 = color, Size = UDim2.new(0.25, -5, 1, 0), LayoutOrder = order, Parent = buttons })
		b.Activated:Connect(function()
			card:Destroy()
			fn()
		end)
		return b
	end
	action("WATCH", colors.panelLight, 1, function()
		openStudio(summary.id, "watch")
	end)
	action("EDIT", Color3.fromRGB(30, 140, 150), 2, function()
		openStudio(summary.id, "edit")
	end)
	action("POST", PINK, 3, function()
		openStudio(summary.id, "post")
	end)
	local delete = UI.button({ Text = "DELETE", TextSize = 13, BackgroundColor3 = Color3.fromRGB(120, 35, 40), Size = UDim2.new(0.25, -5, 1, 0), LayoutOrder = 4, Parent = buttons })
	confirmButton(delete, "DELETE", function()
		local _, msg = request("DeleteClip", summary.id)
		toast(msg)
		card:Destroy()
		if libraryRefresh then
			libraryRefresh()
		end
	end)
	task.delay(12, function()
		if cardToken == token and card.Parent then
			card:Destroy()
		end
	end)
end

---------------------------------------------------------------------------
-- Phone app: feed + library
---------------------------------------------------------------------------
type Feed = {
	items: { any },
	index: number,
	tab: string,
	source: string, -- "tab" | "list"
	listTitle: string,
	more: boolean,
	loading: boolean,
	token: number,
}
local feed: Feed = { items = {}, index = 1, tab = "Recommended", source = "tab", listTitle = "", more = true, loading = false, token = 0 }
local view = "feed" -- "feed" | "library"
local feedStage: Stage? = nil
local feedRefs: { [string]: any } = {}
local currentPost: any = nil
local appOpen = false

local function feedVisible(): boolean
	return appOpen and Phone.isOpen() and Phone.currentPage() == "CityTok" and view == "feed" and not studio.open
end

local function setStat(button: TextButton, icon: string, n: number?)
	button.Text = icon .. "\n" .. countText(n)
end

local function updatePostChrome()
	local post = currentPost
	local r = feedRefs
	r.empty.Visible = post == nil and not feed.loading
	r.side.Visible = post ~= nil
	r.info.Visible = post ~= nil
	if not post then
		return
	end
	r.creator.Text = "@" .. tostring(post.name)
	r.caption.Text = if post.cap and post.cap ~= "" then post.cap else tostring(post.title or "")
	local badge = if post.viral then "🔥 VIRAL  " elseif post.trending then "📈 TRENDING  " else ""
	r.meta.Text = badge .. "#" .. tostring(post.cat) .. "  ·  📍 " .. tostring(post.loc or "") .. "  ·  " .. UI.timeAgo(tonumber(post.t) or os.time())
	local track = currentPost.music and trackName(currentPost.music)
	r.music.Visible = track ~= nil
	r.music.Text = if track then "♪ " .. track else ""
	r.avatar.Text = string.upper(string.sub(tostring(post.name), 1, 1))
	r.follow.Visible = caps.follow and not post.mine
	r.follow.Text = if post.following then "✓" else "+"
	r.follow.BackgroundColor3 = if post.following then colors.panelLight else PINK
	setStat(r.like, if post.liked then "❤️" else "🤍", post.likes)
	r.like.Visible = not post.mine
	setStat(r.comment, "💬", post.comments)
	setStat(r.share, "↗", post.shares)
	r.share.Visible = caps.share
	r.fav.Text = if post.faved then "⭐\nSaved" else "☆\nSave"
	r.views.Text = "👁 " .. countText(post.views)
	r.position.Text = string.format("%d / %d%s", feed.index, #feed.items, if feed.more and feed.source == "tab" then "+" else "")
end

local function hideSheets()
	feedRefs.commentSheet.Visible = false
	feedRefs.shareSheet.Visible = false
end

local function showPost(index: number)
	if not feedStage then
		return
	end
	feed.index = math.clamp(index, 1, math.max(1, #feed.items))
	local post = feed.items[feed.index]
	currentPost = post
	hideSheets()
	stopMusic()
	feed.token += 1
	local token = feed.token
	feedStage.clip = nil
	feedRefs.loadingLabel.Visible = post ~= nil
	updatePostChrome()
	if not post then
		return
	end
	task.spawn(function()
		local ok, msg, data = request("GetPost", post.id)
		if token ~= feed.token or not feedStage then
			return
		end
		feedRefs.loadingLabel.Visible = false
		if not ok or type(data) ~= "table" or type(data.clip) ~= "table" then
			toast(msg or "This video isn't available.")
			return
		end
		-- fresh stats from the server
		for k, v in data.post do
			post[k] = v
		end
		post.music = type(data.edit) == "table" and data.edit.mu or nil
		loadStage(feedStage, data.clip, if type(data.edit) == "table" then data.edit else nil)
		updatePostChrome()
		if feedVisible() then
			previewMusic(post.music)
		end
		-- a view counts once you've actually watched for a moment
		task.delay(Cfg.MIN_WATCH_FOR_VIEW + 0.3, function()
			if token == feed.token and feedVisible() then
				local okView = request("View", post.id)
				if okView and not post.mine and not post.viewedHere then
					post.viewedHere = true
				end
			end
		end)
	end)
end

local function loadFeed(append: boolean)
	if feed.loading or feed.source ~= "tab" then
		return
	end
	feed.loading = true
	local offset = if append then #feed.items else 0
	if not append then
		feed.items = {}
		feed.more = true
		currentPost = nil
		feedRefs.loadingLabel.Visible = true
		updatePostChrome()
	end
	local tab = feed.tab
	local ok, msg, list = request("Feed", { tab = tab, offset = offset })
	feed.loading = false
	feedRefs.loadingLabel.Visible = false
	if tab ~= feed.tab or feed.source ~= "tab" then
		return
	end
	if not ok or type(list) ~= "table" then
		toast(msg)
		updatePostChrome()
		return
	end
	feed.more = #list >= Cfg.PAGE_SIZE
	local seen = {}
	for _, p in feed.items do
		seen[p.id] = true
	end
	for _, p in list do
		if not seen[p.id] then
			table.insert(feed.items, p)
		end
	end
	if not append then
		showPost(1)
	else
		updatePostChrome()
	end
end

local lastNav = 0
local function navigate(delta: number)
	if os.clock() - lastNav < 0.3 or #feed.items == 0 then
		return
	end
	lastNav = os.clock()
	local target = feed.index + delta
	if target > #feed.items then
		if feed.more and feed.source == "tab" then
			task.spawn(function()
				loadFeed(true)
				if feed.index + delta <= #feed.items then
					showPost(feed.index + delta)
				end
			end)
		end
		return
	end
	if target < 1 then
		return
	end
	showPost(target)
	if feed.source == "tab" and feed.more and target >= #feed.items - 2 then
		task.spawn(loadFeed, true)
	end
end

local function selectTab(tab: string)
	feed.tab = tab
	feed.source = "tab"
	for name, b in feedRefs.tabButtons do
		setButtonOn(b, name == tab)
	end
	task.spawn(loadFeed, false)
end

-- Plays a fixed list (Saved, Inbox, My posts) in the feed.
local function playList(items: { any }, index: number, title: string)
	feed.source = "list"
	feed.listTitle = title
	feed.items = items
	feed.more = false
	for _, b in feedRefs.tabButtons do
		setButtonOn(b, false)
	end
	view = "feed"
	feedRefs.feedView.Visible = true
	feedRefs.library.Visible = false
	showPost(index)
	toast("Playing " .. title)
end

local function openComments()
	local post = currentPost
	if not post then
		return
	end
	hideSheets()
	local sheet = feedRefs.commentSheet :: Frame
	local list = feedRefs.commentList :: ScrollingFrame
	Phone.clear(list)
	sheet.Visible = true
	UI.label({ Text = "Loading...", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 18), Parent = list })
	local ok, msg, comments = request("Comments", post.id)
	Phone.clear(list)
	if not ok or type(comments) ~= "table" then
		UI.label({ Text = msg or "Couldn't load comments.", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 18), Parent = list })
		return
	end
	if #comments == 0 then
		UI.label({ Text = "No comments yet. Say something nice!", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 18), Parent = list })
	end
	for i = #comments, 1, -1 do
		local c = comments[i]
		UI.label({
			Text = string.format("<b>%s</b>  <font color=\"#9a9aaa\">%s</font>\n%s", tostring(c.n):gsub("[<>&]", ""), UI.timeAgo(tonumber(c.t) or os.time()), (tostring(c.x):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))),
			RichText = true,
			TextSize = 13,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -6, 0, 0),
			LayoutOrder = #comments - i,
			Parent = list,
		})
	end
end

local function openShare()
	local post = currentPost
	if not post then
		return
	end
	hideSheets()
	local sheet = feedRefs.shareSheet :: Frame
	local list = feedRefs.shareList :: ScrollingFrame
	Phone.clear(list)
	sheet.Visible = true
	local others = {}
	for _, p in Players:GetPlayers() do
		if p ~= player then
			table.insert(others, p)
		end
	end
	table.sort(others, function(a, b)
		return a.DisplayName < b.DisplayName
	end)
	if #others == 0 then
		UI.label({ Text = "Nobody else is in this server right now.", TextSize = 13, TextColor3 = colors.subtext, TextWrapped = true, Size = UDim2.new(1, 0, 0, 36), Parent = list })
	end
	for i, other in others do
		local b = UI.button({ Text = "  " .. other.DisplayName .. "  @" .. other.Name, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -6, 0, 32), LayoutOrder = i, Parent = list })
		b.Activated:Connect(function()
			b.Text = "  Sending..."
			local ok, msg = request("Share", { id = post.id, to = other.UserId })
			toast(msg)
			if ok then
				sheet.Visible = false
				if not post.mine then
					post.shares = (post.shares or 0) + (if post.sharedHere then 0 else 1)
					post.sharedHere = true
				end
				updatePostChrome()
			else
				b.Text = "  " .. other.DisplayName .. "  @" .. other.Name
			end
		end)
	end
end

local function sideButton(parent: Instance, order: number, text: string): TextButton
	return UI.button({
		Text = text,
		TextSize = 13,
		Font = UI.FONT_BOLD,
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.55,
		Size = UDim2.fromOffset(44, 44),
		LayoutOrder = order,
		ZIndex = 12,
		Parent = parent,
	})
end

local function buildFeedView(root: Frame)
	local feedView = UI.new("Frame", { Name = "FeedView", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 1, -70), Parent = root })
	feedRefs.feedView = feedView
	local stageHolder = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -12, 1, 0), Parent = feedView })
	feedStage = newStage(stageHolder, false)
	local stage = feedStage :: Stage

	-- touch swipe / mouse drag / wheel on the video
	local gesture = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = stage.holder })
	local downAt: Vector3? = nil
	gesture.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			downAt = input.Position
		end
	end)
	gesture.InputEnded:Connect(function(input)
		if downAt and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
			local dy = input.Position.Y - downAt.Y
			downAt = nil
			if dy < -45 then
				navigate(1)
			elseif dy > 45 then
				navigate(-1)
			elseif feedStage then
				feedStage.playing = not feedStage.playing
				toast(if feedStage.playing then "▶ Playing" else "❚❚ Paused")
			end
		end
	end)
	gesture.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			navigate(if input.Position.Z > 0 then -1 else 1)
		end
	end)

	-- right column
	local side = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -86), Size = UDim2.fromOffset(46, 320), ZIndex = 12, Parent = stageHolder }, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Bottom }),
	})
	feedRefs.side = side
	local avatar = UI.button({ Text = "?", TextSize = 18, Font = UI.FONT_BLACK, BackgroundColor3 = Color3.fromRGB(70, 70, 90), Size = UDim2.fromOffset(44, 44), LayoutOrder = 1, ZIndex = 12, Parent = side })
	local avatarCorner = avatar:FindFirstChildOfClass("UICorner") :: UICorner
	avatarCorner.CornerRadius = UDim.new(0, 22)
	feedRefs.avatar = avatar
	local follow = UI.button({ Text = "+", TextSize = 16, Font = UI.FONT_BLACK, BackgroundColor3 = PINK, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(20, 20), ZIndex = 13, Parent = avatar })
	local followCorner = follow:FindFirstChildOfClass("UICorner") :: UICorner
	followCorner.CornerRadius = UDim.new(0, 10)
	feedRefs.follow = follow
	feedRefs.like = sideButton(side, 2, "🤍\n0")
	feedRefs.comment = sideButton(side, 3, "💬\n0")
	feedRefs.share = sideButton(side, 4, "↗\n0")
	feedRefs.fav = sideButton(side, 5, "☆\nSave")
	local up = sideButton(side, 6, "▲")
	local down = sideButton(side, 7, "▼")
	up.Activated:Connect(function()
		navigate(-1)
	end)
	down.Activated:Connect(function()
		navigate(1)
	end)

	avatar.Activated:Connect(function()
		local post = currentPost
		local Social = lazyModule("Social")
		if post and Social and type(Social.openProfile) == "function" then
			Social.openProfile(post.by)
		end
	end)
	follow.Activated:Connect(function()
		local post = currentPost
		if not post then
			return
		end
		local ok, msg, data = request("Follow", { to = post.by, on = not post.following })
		toast(msg)
		if ok and type(data) == "table" then
			for _, p in feed.items do
				if p.by == post.by then
					p.following = data.following == true
				end
			end
			updatePostChrome()
		end
	end)
	feedRefs.like.Activated:Connect(function()
		local post = currentPost
		if not post or post.mine then
			return
		end
		local on = not post.liked
		post.liked = on
		post.likes = math.max(0, (post.likes or 0) + (if on then 1 else -1))
		updatePostChrome()
		local ok, msg, data = request("Like", { id = post.id, on = on })
		if not ok then
			post.liked = not on
			post.likes = math.max(0, (post.likes or 0) + (if on then -1 else 1))
			toast(msg)
		elseif type(data) == "table" and type(data.likes) == "number" then
			post.likes = data.likes
		end
		updatePostChrome()
	end)
	feedRefs.comment.Activated:Connect(function()
		task.spawn(openComments)
	end)
	feedRefs.share.Activated:Connect(openShare)
	feedRefs.fav.Activated:Connect(function()
		local post = currentPost
		if not post then
			return
		end
		local ok, msg = request("Fav", { id = post.id, on = not post.faved })
		toast(msg)
		if ok then
			post.faved = not post.faved
			updatePostChrome()
		end
	end)

	-- bottom-left info
	local info = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 10, 1, -8), Size = UDim2.new(1, -72, 0, 96), ZIndex = 12, Parent = stageHolder })
	feedRefs.info = info
	feedRefs.creator = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 15, TextStrokeTransparency = 0.4, Size = UDim2.new(1, 0, 0, 18), ZIndex = 12, Parent = info })
	feedRefs.caption = UI.label({ Text = "", TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextStrokeTransparency = 0.5, Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 34), ZIndex = 12, Parent = info })
	feedRefs.meta = UI.label({ Text = "", TextSize = 11, TextColor3 = Color3.fromRGB(220, 220, 230), TextStrokeTransparency = 0.5, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(0, 56), Size = UDim2.new(1, 0, 0, 14), ZIndex = 12, Parent = info })
	feedRefs.music = UI.label({ Text = "", TextSize = 11, TextColor3 = GOLD, TextStrokeTransparency = 0.5, Position = UDim2.fromOffset(0, 72), Size = UDim2.new(1, 0, 0, 14), Visible = false, ZIndex = 12, Parent = info })
	feedRefs.views = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 11, TextStrokeTransparency = 0.4, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 40), Size = UDim2.fromOffset(120, 14), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 12, Parent = stageHolder })
	feedRefs.position = UI.label({ Text = "", TextSize = 11, TextColor3 = Color3.fromRGB(220, 220, 230), TextStrokeTransparency = 0.4, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 56), Size = UDim2.fromOffset(120, 14), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 12, Parent = stageHolder })

	feedRefs.loadingLabel = UI.label({ Text = "Loading...", Font = UI.FONT_BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 0, 0, 20), Visible = false, ZIndex = 14, Parent = stageHolder })
	local empty = UI.new("Frame", { BackgroundColor3 = colors.panel, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 14, Parent = stageHolder }, { UI.corner(12), UI.padding(16) })
	feedRefs.empty = empty
	UI.label({ Text = "🎬", TextSize = 40, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.2), Size = UDim2.new(1, 0, 0, 44), ZIndex = 14, Parent = empty })
	UI.label({ Text = "No videos here yet.\nPlay ball, drive, train — highlights save automatically. Post one from your Library!", TextSize = 14, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0, 0.35), Size = UDim2.new(1, 0, 0, 80), ZIndex = 14, Parent = empty })
	local goLibrary = UI.button({ Text = "Open Library", BackgroundColor3 = PINK, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.62), Size = UDim2.fromOffset(150, 36), ZIndex = 14, Parent = empty })
	feedRefs.goLibrary = goLibrary

	-- comment sheet
	local commentSheet = UI.new("Frame", { BackgroundColor3 = colors.panel, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.7, 0), Visible = false, ZIndex = 20, Parent = stageHolder }, { UI.corner(12), UI.padding(8) })
	feedRefs.commentSheet = commentSheet
	UI.label({ Text = "COMMENTS", Font = UI.FONT_BLACK, TextSize = 14, Size = UDim2.new(1, -40, 0, 20), ZIndex = 20, Parent = commentSheet })
	local closeComments = UI.button({ Text = "✕", TextSize = 14, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(28, 22), ZIndex = 20, Parent = commentSheet })
	closeComments.Activated:Connect(function()
		commentSheet.Visible = false
	end)
	feedRefs.commentList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 1, -64),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ZIndex = 20,
		Parent = commentSheet,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local commentBox = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "Add a comment...",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		BackgroundColor3 = colors.panelLight,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, -62, 0, 34),
		ZIndex = 20,
		Parent = commentSheet,
	}, { UI.corner(8), UI.padding(6) }) :: TextBox
	commentBox:GetPropertyChangedSignal("Text"):Connect(function()
		local len = utf8.len(commentBox.Text)
		if len and len > Cfg.COMMENT_MAX then
			commentBox.Text = commentBox.Text:sub(1, (utf8.offset(commentBox.Text, Cfg.COMMENT_MAX + 1) :: number) - 1)
		end
	end)
	local send = UI.button({ Text = "Send", TextSize = 13, BackgroundColor3 = PINK, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(56, 34), ZIndex = 20, Parent = commentSheet })
	local function sendComment()
		local post = currentPost
		if not post or commentBox.Text == "" then
			return
		end
		send.Text = "..."
		local ok, msg = request("Comment", { id = post.id, text = commentBox.Text })
		send.Text = "Send"
		if ok then
			commentBox.Text = ""
			post.comments = (post.comments or 0) + 1
			updatePostChrome()
			openComments()
		else
			toast(msg)
		end
	end
	send.Activated:Connect(sendComment)
	commentBox.FocusLost:Connect(function(enter)
		if enter then
			sendComment()
		end
	end)

	-- share sheet
	local shareSheet = UI.new("Frame", { BackgroundColor3 = colors.panel, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.6, 0), Visible = false, ZIndex = 20, Parent = stageHolder }, { UI.corner(12), UI.padding(8) })
	feedRefs.shareSheet = shareSheet
	UI.label({ Text = "SEND TO A PLAYER", Font = UI.FONT_BLACK, TextSize = 14, Size = UDim2.new(1, -40, 0, 20), ZIndex = 20, Parent = shareSheet })
	local closeShare = UI.button({ Text = "✕", TextSize = 14, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(28, 22), ZIndex = 20, Parent = shareSheet })
	closeShare.Activated:Connect(function()
		shareSheet.Visible = false
	end)
	feedRefs.shareList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 1, -24),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ZIndex = 20,
		Parent = shareSheet,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
end

-- Library: my clips, my posts, saved, inbox
local libraryTab = "Clips"

local function libraryRow(parent: Instance, order: number, height: number): Frame
	return UI.new("Frame", { BackgroundColor3 = colors.panelLight, Size = UDim2.new(1, -8, 0, height), LayoutOrder = order, Parent = parent }, { UI.corner(10), UI.padding(8) })
end

local function rowButtons(parent: Instance): Frame
	return UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 26), Parent = parent }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

local function smallButton(parent: Instance, text: string, color: Color3?, order: number): TextButton
	return UI.button({ Text = text, TextSize = 11, BackgroundColor3 = color or Color3.fromRGB(55, 55, 70), Size = UDim2.fromOffset(56, 26), LayoutOrder = order, Parent = parent })
end

local function renderLibrary()
	local list = feedRefs.libraryList :: ScrollingFrame
	for name, b in feedRefs.libTabs do
		setButtonOn(b, name == libraryTab)
	end
	Phone.clear(list)
	local loading = UI.label({ Text = "Loading...", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 999, Parent = list })
	local tab = libraryTab
	if tab == "Clips" then
		local ok, msg, clips = request("MyClips")
		if libraryTab ~= tab then
			return
		end
		loading:Destroy()
		if not ok or type(clips) ~= "table" then
			UI.label({ Text = msg or "Couldn't load clips.", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 18), Parent = list })
			return
		end
		if #clips == 0 then
			UI.label({ Text = "No clips yet. Dunks, threes, blocks, steals, big air and top-speed runs save here automatically — or tap CLIP IT.", TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -8, 0, 64), Parent = list })
		end
		for i, c in clips do
			local r = libraryRow(list, i, 84)
			UI.label({ Text = (Cfg.KIND_ICON[c.kind] or "🎬") .. " " .. tostring(c.title), Font = UI.FONT_BLACK, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 16), Parent = r })
			UI.label({
				Text = string.format("📍 %s · %.0fs · %s%s%s", tostring(c.loc or ""), tonumber(c.dur) or 0, UI.timeAgo(tonumber(c.at) or os.time()), if c.edited then " · edited" else "", if c.posted then " · POSTED" else ""),
				TextSize = 11,
				TextColor3 = colors.subtext,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Position = UDim2.fromOffset(0, 18),
				Size = UDim2.new(1, 0, 0, 14),
				Parent = r,
			})
			local buttons = rowButtons(r)
			smallButton(buttons, "WATCH", nil, 1).Activated:Connect(function()
				openStudio(c.id, "watch")
			end)
			smallButton(buttons, "EDIT", Color3.fromRGB(30, 140, 150), 2).Activated:Connect(function()
				openStudio(c.id, "edit")
			end)
			if not c.posted then
				smallButton(buttons, "POST", PINK, 3).Activated:Connect(function()
					openStudio(c.id, "post")
				end)
			end
			local del = smallButton(buttons, "DELETE", Color3.fromRGB(120, 35, 40), 4)
			confirmButton(del, "DELETE", function()
				local okDel, delMsg = request("DeleteClip", c.id)
				toast(delMsg)
				if okDel then
					renderLibrary()
				end
			end)
		end
		return
	end

	local action = if tab == "Posts" then "MyPosts" elseif tab == "Saved" then "Favs" else "Inbox"
	local ok, msg, posts = request(action)
	if libraryTab ~= tab then
		return
	end
	loading:Destroy()
	if not ok or type(posts) ~= "table" then
		UI.label({ Text = msg or "Couldn't load.", TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 18), Parent = list })
		return
	end
	if #posts == 0 then
		local emptyText = if tab == "Posts" then "You haven't posted yet. Open a clip and tap POST." elseif tab == "Saved" then "Tap ☆ on any video to save it here." else "Videos friends send you land here."
		UI.label({ Text = emptyText, TextSize = 13, TextWrapped = true, TextColor3 = colors.subtext, Size = UDim2.new(1, -8, 0, 40), Parent = list })
	end
	for i, p in posts do
		local r = libraryRow(list, i, 84)
		local head = if tab == "Inbox" and p.sharedBy then "From " .. tostring(p.sharedBy) .. ": " else ""
		UI.label({ Text = head .. "@" .. tostring(p.name) .. "  " .. (if p.cap and p.cap ~= "" then p.cap else tostring(p.title)), Font = UI.FONT_BOLD, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, 16), Parent = r })
		local badge = if p.viral then "🔥 VIRAL · " elseif p.trending then "📈 TRENDING · " else ""
		UI.label({
			Text = string.format("%s❤ %s  👁 %s  💬 %s  ↗ %s · %s", badge, countText(p.likes), countText(p.views), countText(p.comments), countText(p.shares), UI.timeAgo(tonumber(p.t) or os.time())),
			TextSize = 11,
			TextColor3 = colors.subtext,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(0, 18),
			Size = UDim2.new(1, 0, 0, 14),
			Parent = r,
		})
		local buttons = rowButtons(r)
		smallButton(buttons, "WATCH", PINK, 1).Activated:Connect(function()
			playList(posts, i, if tab == "Posts" then "My posts" elseif tab == "Saved" then "Saved" else "Inbox")
		end)
		if tab == "Posts" then
			local del = smallButton(buttons, "DELETE", Color3.fromRGB(120, 35, 40), 2)
			confirmButton(del, "DELETE", function()
				local okDel, delMsg = request("DeletePost", p.id)
				toast(delMsg)
				if okDel then
					renderLibrary()
				end
			end)
		elseif tab == "Saved" then
			smallButton(buttons, "UNSAVE", nil, 2).Activated:Connect(function()
				local okFav, favMsg = request("Fav", { id = p.id, on = false })
				toast(favMsg)
				if okFav then
					renderLibrary()
				end
			end)
		end
	end
end

local function showLibrary()
	view = "library"
	feedRefs.feedView.Visible = false
	feedRefs.library.Visible = true
	hideSheets()
	task.spawn(renderLibrary)
end

local function showFeed()
	view = "feed"
	feedRefs.feedView.Visible = true
	feedRefs.library.Visible = false
	if feed.source ~= "tab" or #feed.items == 0 then
		selectTab(feed.tab)
	end
end

local function buildLibrary(root: Frame)
	local library = UI.new("Frame", { Name = "Library", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 1, -40), Visible = false, Parent = root })
	feedRefs.library = library
	local tabs = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -12, 0, 28), Parent = library }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	feedRefs.libTabs = {}
	for i, name in { "Clips", "Posts", "Saved", "Inbox" } do
		local b = pill({ Text = name, TextSize = 12, Size = UDim2.new(0.25, -3, 1, 0), LayoutOrder = i, Parent = tabs })
		feedRefs.libTabs[name] = b
		b.Activated:Connect(function()
			libraryTab = name
			task.spawn(renderLibrary)
		end)
	end
	feedRefs.libraryList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 34),
		Size = UDim2.new(1, -6, 1, -34),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = library,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
end

local function buildApp(content: ScrollingFrame, frame: Frame): () -> ()
	content.Visible = false
	local root = UI.new("Frame", { Name = "CityTokRoot", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 76), Size = UDim2.new(1, 0, 1, -104), Parent = frame })

	-- feed tabs
	local tabStrip = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -12, 0, 26),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		Parent = root,
	}, { UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	feedRefs.tabStrip = tabStrip
	feedRefs.tabButtons = {}
	for i, tab in Cfg.TABS do
		local label = if tab == "Recommended" then "For You" else tab
		local b = pill({ Text = label, TextSize = 12, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i, Parent = tabStrip })
		UI.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = b })
		feedRefs.tabButtons[tab] = b
		b.Activated:Connect(function()
			showFeed()
			selectTab(tab)
		end)
	end

	buildFeedView(root)
	buildLibrary(root)
	feedRefs.goLibrary.Activated:Connect(showLibrary)

	-- bottom nav
	local nav = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 6, 1, 0), Size = UDim2.new(1, -12, 0, 34), Parent = root }, {
		UI.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local feedButton = pill({ Text = "▶ Feed", Size = UDim2.new(1 / 3, -4, 1, 0), LayoutOrder = 1, Parent = nav })
	local clipButton = pill({ Text = "🎬 Clip it", BackgroundColor3 = PINK, Size = UDim2.new(1 / 3, -4, 1, 0), LayoutOrder = 2, Parent = nav })
	local libButton = pill({ Text = "📁 Library", Size = UDim2.new(1 / 3, -4, 1, 0), LayoutOrder = 3, Parent = nav })
	feedButton.Activated:Connect(showFeed)
	libButton.Activated:Connect(showLibrary)
	clipButton.Activated:Connect(function()
		local _, msg = request("ClipNow")
		toast(msg)
	end)

	toastLabel = UI.label({
		Text = "",
		Font = UI.FONT_BOLD,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.25,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 34),
		Size = UDim2.new(1, -40, 0, 36),
		Visible = false,
		ZIndex = 30,
		Parent = root,
	}, { UI.corner(10) })

	libraryRefresh = function()
		if view == "library" and appOpen then
			task.spawn(renderLibrary)
		end
	end

	return function()
		appOpen = true
		if view == "library" then
			task.spawn(renderLibrary)
		elseif #feed.items == 0 and feed.source == "tab" then
			selectTab(feed.tab)
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function CityTok.start()
	Phone.addApp({ id = "CityTok", label = "CityTok", icon = "🎬", color = PINK }, buildApp)

	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		Request = remotes:WaitForChild("CityTokRequest") :: RemoteFunction
		local Event = remotes:WaitForChild("CityTokEvent") :: RemoteEvent

		cardGui = UI.new("ScreenGui", { Name = "CityTokHighlight", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 7, Parent = player:WaitForChild("PlayerGui") })
		buildStudio()

		Event.OnClientEvent:Connect(function(kind: string, data: any)
			if kind == "Highlight" then
				showHighlight(data)
				if libraryTab == "Clips" and libraryRefresh then
					libraryRefresh()
				end
			elseif kind == "Inbox" then
				if libraryTab == "Inbox" and libraryRefresh then
					libraryRefresh()
				end
			end
		end)

		local ok, _, data = request("Caps")
		if ok and type(data) == "table" then
			caps.follow = data.follow == true
			caps.share = data.share == true
		end
		if feedRefs.tabButtons and feedRefs.tabButtons.Following then
			feedRefs.tabButtons.Following.Visible = caps.follow
		end
	end)

	-- Pause the feed when it's not on screen; L1/R1 and PageUp/PageDown flip videos while it is.
	local bound = false
	RunService.Heartbeat:Connect(function()
		local visible = feedVisible()
		if Phone.currentPage() ~= "CityTok" or not Phone.isOpen() then
			appOpen = appOpen and Phone.currentPage() == "CityTok"
		end
		if feedStage then
			if feedStage.active and not visible and not studio.open then
				stopMusic()
			end
			feedStage.active = visible
		end
		if visible and not bound then
			bound = true
			ContextActionService:BindActionAtPriority("CityTokFeed", function(_, state, input)
				if state ~= Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Pass
				end
				if input.KeyCode == Enum.KeyCode.ButtonR1 or input.KeyCode == Enum.KeyCode.PageDown then
					navigate(1)
				else
					navigate(-1)
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonR1, Enum.KeyCode.ButtonL1, Enum.KeyCode.PageDown, Enum.KeyCode.PageUp)
		elseif not visible and bound then
			bound = false
			ContextActionService:UnbindAction("CityTokFeed")
		end
	end)
end

return CityTok
