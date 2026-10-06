-- CITY GRIND: phone calls (sections 19, 20, 101). Client side.
-- * Incoming call screen (ACCEPT / DECLINE) with a silent visual pulse.
-- * Call screen on both phones: avatar, timer, Voice/Text badge, MUTE, SPEAKER, END,
--   minimise to a small pill so the phone stays usable during a call.
-- * Voice calls use only Roblox voice chat through the audio API: the other
--   player's AudioDeviceInput is wired to a local AudioFader -> AudioDeviceOutput.
--   Without voice for both players the call is a live TEXT call (server-filtered,
--   never stored).
-- * "Calls" phone app: Recents + Contacts, call buttons.
-- * "CALL" in the player interaction menu (Social.addMenuAction).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local CC = require(shared:WaitForChild("CallsConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Calls = {}

local APP_ID = "Calls"
local GREEN = Color3.fromRGB(50, 190, 100)
local RED = Color3.fromRGB(230, 60, 70)
local CALL_W, CALL_H = 300, 600

type Snapshot = {
	id: number,
	state: string,
	mode: string,
	outgoing: boolean,
	otherId: number,
	otherName: string,
	otherUsername: string,
	ringEndsAt: number,
	startedAt: number,
	otherMuted: boolean,
}

local CallAction: RemoteFunction? = nil
local current: Snapshot? = nil
local recents: { any }? = nil
local muted = false
local speaker = false
local minimized = false
local tab = "Recents"

-- UI handles (built in buildScreens)
local gui: ScreenGui
local callFrame: Frame
local uiScale: UIScale
local avatar: ImageLabel
local rings: { Frame } = {}
local ringTweens: { Tween } = {}
local nameLabel: TextLabel
local userLabel: TextLabel
local statusLabel: TextLabel
local modeBadge: TextLabel
local otherMutedLabel: TextLabel
local incomingRow: Frame
local acceptButton: TextButton
local voiceRow: Frame
local muteButton: TextButton
local speakerButton: TextButton
local endButton: TextButton
local endCaption: TextLabel
local textPanel: Frame
local chatList: ScrollingFrame
local chatBox: TextBox
local minimizeButton: TextButton
local pill: TextButton
local pillText: TextLabel
local endedUntil = 0
local chatOrder = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function invoke(action: string, a: any?): (boolean, string?, any)
	if not CallAction then
		return false, "Calls are still connecting.", nil
	end
	local ok, success, message, data = pcall(function()
		return (CallAction :: RemoteFunction):InvokeServer(action, a)
	end)
	if not ok then
		return false, "Calls are unavailable right now.", nil
	end
	return success == true, message, data
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return string.format("%d:%02d:%02d", seconds // 3600, (seconds % 3600) // 60, seconds % 60)
	end
	return string.format("%02d:%02d", seconds // 60, seconds % 60)
end

local thumbs: { [number]: string } = {}
local function setHeadshot(image: ImageLabel, userId: number)
	image.Image = thumbs[userId] or ""
	if thumbs[userId] then
		return
	end
	task.spawn(function()
		local ok, result = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and type(result) == "string" then
			thumbs[userId] = result
			image.Image = result
		end
	end)
end

local function inThisServer(userId: number): boolean
	return Players:GetPlayerByUserId(userId) ~= nil
end

---------------------------------------------------------------------------
-- Voice route (Roblox voice through the audio API only)
---------------------------------------------------------------------------
local route: { folder: Folder, fader: AudioFader }? = nil
local routeToken = 0

local function myInput(): AudioDeviceInput?
	return player:FindFirstChildWhichIsA("AudioDeviceInput", true) :: AudioDeviceInput?
end

local function setOwnMute(value: boolean)
	local input = myInput()
	if input then
		pcall(function()
			(input :: AudioDeviceInput).Muted = value
		end)
	end
end

local function disconnectVoice()
	routeToken += 1
	if route then
		route.folder:Destroy()
		route = nil
	end
end

local function connectVoice(otherId: number)
	disconnectVoice()
	routeToken += 1
	local token = routeToken
	task.spawn(function()
		local other = Players:GetPlayerByUserId(otherId)
		local deadline = os.clock() + 6
		local input: AudioDeviceInput? = nil
		while other and other.Parent and os.clock() < deadline and token == routeToken do
			input = other:FindFirstChildWhichIsA("AudioDeviceInput", true) :: AudioDeviceInput?
			if input then
				break
			end
			task.wait(0.25)
		end
		if token ~= routeToken then
			return
		end
		if not input then
			statusLabel.Text = "Voice unavailable for this call"
			return
		end
		local ok, err = pcall(function()
			local folder = Instance.new("Folder")
			folder.Name = "CityGrindCallAudio"
			local fader = Instance.new("AudioFader")
			fader.Volume = if speaker then CC.SPEAKER_VOLUME else CC.EARPIECE_VOLUME
			fader.Parent = folder
			local out = Instance.new("AudioDeviceOutput")
			pcall(function()
				out.Player = player
			end)
			out.Parent = folder
			local w1 = Instance.new("Wire")
			w1.SourceInstance = input :: AudioDeviceInput
			w1.TargetInstance = fader
			w1.Parent = fader
			local w2 = Instance.new("Wire")
			w2.SourceInstance = fader
			w2.TargetInstance = out
			w2.Parent = out
			folder.Parent = SoundService
			route = { folder = folder, fader = fader }
		end)
		if not ok then
			warn("[CityGrind] call voice route failed:", err)
			statusLabel.Text = "Voice unavailable for this call"
		end
	end)
end

local function applySpeaker()
	if route then
		route.fader.Volume = if speaker then CC.SPEAKER_VOLUME else CC.EARPIECE_VOLUME
	end
end

---------------------------------------------------------------------------
-- Call screen
---------------------------------------------------------------------------
local function roundButton(parent: Instance, text: string, caption: string, color: Color3, x: number, size: number): (TextButton, TextLabel)
	local b = UI.new("TextButton", {
		Text = text,
		Font = UI.FONT_BLACK,
		TextSize = math.floor(size * 0.38),
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = color,
		AutoButtonColor = true,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(x, 0, 0, 0),
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	}, { UI.corner(math.floor(size / 2)) })
	local captionLabel = UI.label({
		Name = "Caption",
		Text = caption,
		Font = UI.FONT_BOLD,
		TextSize = 12,
		TextColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(x, 0, 0, size + 4),
		Size = UDim2.fromOffset(size + 30, 14),
		Parent = parent,
	})
	return b, captionLabel
end

local function setToggle(button: TextButton, on: boolean)
	button.BackgroundColor3 = if on then Color3.fromRGB(235, 235, 240) else Color3.fromRGB(60, 60, 72)
	button.TextColor3 = if on then Color3.fromRGB(20, 20, 26) else Color3.new(1, 1, 1)
end

local pulsing = false
local function setPulse(on: boolean)
	if on == pulsing then
		return
	end
	pulsing = on
	for i, ring in rings do
		local tween = ringTweens[i]
		if on then
			ring.Visible = true
			tween:Play()
		else
			tween:Cancel()
			ring.Visible = false
			ring.Size = UDim2.fromOffset(110, 110)
			ring.BackgroundTransparency = 0.55
		end
	end
end

local function applyScale()
	local camera = Workspace.CurrentCamera
	local viewportH = if camera then camera.ViewportSize.Y else 800
	uiScale.Scale = math.min(1, (viewportH - 140) / (CALL_H + 20)) * (player:GetAttribute("UIScale") or 1)
end

local function addChatLine(fromMe: boolean, name: string, text: string)
	chatOrder += 1
	local bubble = UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = chatOrder,
		Parent = chatList,
	})
	UI.label({
		Text = (if fromMe then "You" else name) .. ":  " .. text,
		TextSize = 13,
		TextWrapped = true,
		RichText = false,
		TextColor3 = if fromMe then colors.xp else colors.text,
		TextXAlignment = if fromMe then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
		BackgroundColor3 = if fromMe then Color3.fromRGB(28, 44, 70) else colors.panelLight,
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = bubble,
	}, { UI.corner(10), UI.padding(7) })
	local lines = {}
	for _, child in chatList:GetChildren() do
		if child:IsA("Frame") then
			table.insert(lines, child)
		end
	end
	if #lines > CC.TEXT_HISTORY then
		table.sort(lines, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		for i = 1, #lines - CC.TEXT_HISTORY do
			lines[i]:Destroy()
		end
	end
	task.defer(function()
		chatList.CanvasPosition = Vector2.new(0, math.max(0, chatList.AbsoluteCanvasSize.Y - chatList.AbsoluteSize.Y))
	end)
end

local function clearChat()
	for _, child in chatList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	chatOrder = 0
end

local function showFrame(visible: boolean)
	callFrame.Visible = visible and not minimized
	pill.Visible = visible and minimized
end

-- Lays the screen out for the current snapshot.
local function render()
	local snap = current
	if not snap then
		if os.clock() >= endedUntil then
			showFrame(false)
			setPulse(false)
		end
		return
	end
	if endedUntil > os.clock() then
		endedUntil = 0
	end
	setHeadshot(avatar, snap.otherId)
	nameLabel.Text = snap.otherName
	userLabel.Text = "@" .. snap.otherUsername
	local voice = snap.mode == "voice"
	modeBadge.Text = if voice then "🎙  VOICE CALL" else "💬  TEXT CALL"
	modeBadge.BackgroundColor3 = if voice then Color3.fromRGB(40, 120, 220) else Color3.fromRGB(150, 80, 220)
	local ringing = snap.state == "ringing"
	local incoming = ringing and not snap.outgoing
	incomingRow.Visible = incoming
	endButton.Visible = not incoming
	endCaption.Visible = not incoming
	endCaption.Text = if ringing then "CANCEL" else "END"
	voiceRow.Visible = voice and snap.state == "active"
	textPanel.Visible = not voice and snap.state == "active"
	otherMutedLabel.Visible = voice and snap.state == "active" and snap.otherMuted
	minimizeButton.Visible = snap.state == "active"
	if snap.state ~= "active" then
		minimized = false
	end
	setToggle(muteButton, muted)
	setToggle(speakerButton, speaker)
	setPulse(ringing)
	showFrame(true)
	if incoming and UserInputService.GamepadEnabled then
		GuiService.SelectedObject = acceptButton
	end
end

local function buildScreens()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindCall",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 8,
		Parent = player:WaitForChild("PlayerGui"),
	})
	callFrame = UI.new("Frame", {
		Name = "Call",
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -24, 0.5, 40),
		Size = UDim2.fromOffset(CALL_W, CALL_H),
		Visible = false,
		Parent = gui,
	}, { UI.corner(42), UI.stroke(Color3.fromRGB(70, 70, 80), 2) })
	uiScale = UI.new("UIScale", { Parent = callFrame })
	local screen = UI.new("Frame", {
		Name = "Screen",
		BackgroundColor3 = Color3.new(1, 1, 1),
		ClipsDescendants = true,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 1, -20),
		Parent = callFrame,
	}, {
		UI.corner(34),
		UI.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromRGB(26, 34, 52), Color3.fromRGB(8, 8, 14)) }),
	})

	minimizeButton = UI.button({
		Text = "‹ Phone",
		TextSize = 14,
		BackgroundTransparency = 1,
		TextColor3 = colors.xp,
		Position = UDim2.fromOffset(10, 30),
		Size = UDim2.fromOffset(80, 28),
		Parent = screen,
	})
	minimizeButton.Activated:Connect(function()
		minimized = true
		render()
	end)

	-- avatar + silent pulse rings
	local avatarHolder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 150), Size = UDim2.fromOffset(110, 110), Parent = screen })
	for i = 1, 2 do
		local ring = UI.new("Frame", {
			BackgroundColor3 = GREEN,
			BackgroundTransparency = 0.55,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(110, 110),
			Visible = false,
			ZIndex = 1,
			Parent = avatarHolder,
		}, { UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
		rings[i] = ring
		ringTweens[i] = TweenService:Create(
			ring,
			TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, (i - 1) * 0.8),
			{ Size = UDim2.fromOffset(200, 200), BackgroundTransparency = 1 }
		)
	end
	avatar = UI.new("ImageLabel", {
		BackgroundColor3 = colors.panelLight,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(110, 110),
		ZIndex = 2,
		Parent = avatarHolder,
	}, { UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }), UI.stroke(Color3.new(1, 1, 1), 2, 0.4) })

	nameLabel = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 26, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(10, 222), Size = UDim2.new(1, -20, 0, 30), Parent = screen })
	userLabel = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(10, 252), Size = UDim2.new(1, -20, 0, 16), Parent = screen })
	statusLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(10, 274), Size = UDim2.new(1, -20, 0, 20), Parent = screen })
	modeBadge = UI.label({
		Text = "",
		Font = UI.FONT_BLACK,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		BackgroundTransparency = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 300),
		Size = UDim2.fromOffset(130, 24),
		Parent = screen,
	}, { UI.corner(12) })
	otherMutedLabel = UI.label({ Text = "Muted their mic", TextSize = 12, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(10, 328), Size = UDim2.new(1, -20, 0, 14), Visible = false, Parent = screen })

	-- incoming: ACCEPT / DECLINE
	incomingRow = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -60), Size = UDim2.new(1, 0, 0, 96), Visible = false, Parent = screen })
	local declineButton = roundButton(incomingRow, "📵", "DECLINE", RED, 0.27, 72)
	acceptButton = roundButton(incomingRow, "📞", "ACCEPT", GREEN, 0.73, 72)
	acceptButton.Activated:Connect(function()
		local snap = current
		if snap then
			local ok, message = invoke("accept", snap.id)
			if not ok and message then
				HUD.push("CALL", message)
			end
		end
	end)
	declineButton.Activated:Connect(function()
		local snap = current
		if snap then
			invoke("decline", snap.id)
		end
	end)

	-- voice controls
	voiceRow = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 372), Size = UDim2.new(1, 0, 0, 90), Visible = false, Parent = screen })
	muteButton = roundButton(voiceRow, "🎤", "MUTE", Color3.fromRGB(60, 60, 72), 0.3, 62)
	speakerButton = roundButton(voiceRow, "🔊", "SPEAKER", Color3.fromRGB(60, 60, 72), 0.7, 62)
	muteButton.Activated:Connect(function()
		if not current or current.mode ~= "voice" then
			return
		end
		muted = not muted
		setOwnMute(muted)
		invoke("mute", muted)
		render()
	end)
	speakerButton.Activated:Connect(function()
		speaker = not speaker
		applySpeaker()
		render()
	end)

	-- text call chat (never stored; lines vanish when the call ends)
	textPanel = UI.new("Frame", { BackgroundColor3 = Color3.fromRGB(14, 14, 20), BackgroundTransparency = 0.2, Position = UDim2.fromOffset(10, 330), Size = UDim2.new(1, -20, 0, 142), Visible = false, Parent = screen }, { UI.corner(14) })
	chatList = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 1, -48),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = textPanel,
	}, { UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	chatBox = UI.new("TextBox", {
		Text = "",
		PlaceholderText = "Type to talk...",
		ClearTextOnFocus = false,
		Font = UI.FONT,
		TextSize = 13,
		TextColor3 = colors.text,
		PlaceholderColor3 = colors.subtext,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = colors.panelLight,
		Position = UDim2.new(0, 6, 1, -38),
		Size = UDim2.new(1, -74, 0, 32),
		Parent = textPanel,
	}, { UI.corner(10), UI.padding(8) })
	local sendButton = UI.button({ Text = "SEND", TextSize = 12, BackgroundColor3 = Color3.fromRGB(150, 80, 220), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 1, -38), Size = UDim2.fromOffset(58, 32), Parent = textPanel })
	local sending = false
	local function send()
		local text = chatBox.Text
		if sending or text:match("^%s*$") then
			return
		end
		if utf8.len(text) and (utf8.len(text) :: number) > CC.TEXT_MAX then
			HUD.push("CALL", "Keep it under " .. CC.TEXT_MAX .. " characters.")
			return
		end
		sending = true
		local ok, message = invoke("text", text)
		sending = false
		if ok then
			chatBox.Text = ""
		elseif message then
			HUD.push("CALL", message)
		end
	end
	sendButton.Activated:Connect(send)
	chatBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			send()
		end
	end)

	-- END / CANCEL
	local endHolder = UI.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -14), Size = UDim2.new(1, 0, 0, 86), Parent = screen })
	endButton, endCaption = roundButton(endHolder, "📵", "END", RED, 0.5, 66)
	endButton.Activated:Connect(function()
		invoke("end")
	end)

	-- minimised pill (tap to return; END on the right)
	pill = UI.new("TextButton", {
		Name = "CallPill",
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = Color3.fromRGB(30, 140, 70),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 150),
		Size = UDim2.fromOffset(240, 40),
		Visible = false,
		Parent = gui,
	}, { UI.corner(20) })
	pillText = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -70, 1, 0), Parent = pill })
	local pillEnd = UI.button({ Text = "END", TextSize = 12, BackgroundColor3 = RED, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(50, 28), Parent = pill })
	pill.Activated:Connect(function()
		minimized = false
		render()
	end)
	pillEnd.Activated:Connect(function()
		invoke("end")
	end)

	applyScale()
	player:GetAttributeChangedSignal("UIScale"):Connect(applyScale)
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end

	-- live timer / countdown
	RunService.Heartbeat:Connect(function()
		local snap = current
		if not snap then
			return
		end
		if snap.state == "ringing" then
			local left = math.max(0, math.ceil(snap.ringEndsAt - serverNow()))
			statusLabel.Text = (if snap.outgoing then "Calling..." else "Incoming call") .. "  ·  " .. left .. "s"
			pillText.Text = "📞 " .. snap.otherName
		else
			local t = clock(serverNow() - snap.startedAt)
			if not statusLabel.Text:find("unavailable") then
				statusLabel.Text = t
			end
			pillText.Text = "📞 " .. snap.otherName .. "  ·  " .. t
		end
	end)
end

---------------------------------------------------------------------------
-- Server events
---------------------------------------------------------------------------
local function onCallEnded(info: any)
	local wasVoice = current ~= nil and current.mode == "voice"
	current = nil
	disconnectVoice()
	if muted and wasVoice then
		setOwnMute(false)
	end
	muted = false
	speaker = false
	minimized = false
	clearChat()
	chatBox.Text = ""
	setPulse(false)
	if type(info) == "table" and info.wasActive then
		-- show "Call ended" on the screen for a moment
		statusLabel.Text = "Call ended  ·  " .. clock(tonumber(info.duration) or 0)
		incomingRow.Visible = false
		voiceRow.Visible = false
		textPanel.Visible = false
		endButton.Visible = false
		endCaption.Visible = false
		minimizeButton.Visible = false
		otherMutedLabel.Visible = false
		callFrame.Visible = true
		pill.Visible = false
		endedUntil = os.clock() + 1.6
		task.delay(1.7, render)
	else
		endedUntil = 0
		render()
	end
	Phone.refresh(APP_ID)
end

local function onEvent(kind: string, payload: any)
	if kind == "incoming" or kind == "state" then
		if type(payload) ~= "table" then
			return
		end
		local previous = current
		current = payload
		if payload.state == "active" and payload.mode == "voice" and (not previous or previous.state ~= "active" or previous.id ~= payload.id) then
			statusLabel.Text = ""
			connectVoice(payload.otherId)
		end
		if not previous or previous.id ~= payload.id then
			muted = false
			speaker = false
			minimized = false
			clearChat()
		end
		render()
		Phone.refresh(APP_ID)
	elseif kind == "ended" then
		onCallEnded(payload)
	elseif kind == "text" then
		if type(payload) == "table" and current and payload.callId == current.id and type(payload.text) == "string" then
			addChatLine(payload.fromId == player.UserId, tostring(payload.name), payload.text)
		end
	elseif kind == "recents" then
		if type(payload) == "table" then
			recents = payload
			Phone.refresh(APP_ID)
		end
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Starts a call to a player in this server.
function Calls.call(userId: number)
	if current then
		HUD.push("CALL", "You're already on a call.")
		minimized = false
		render()
		return
	end
	local ok, message = invoke("call", userId)
	if not ok then
		HUD.push("CALL", message or "Couldn't place the call.")
	end
end

function Calls.inCall(): boolean
	return current ~= nil
end

---------------------------------------------------------------------------
-- Phone app
---------------------------------------------------------------------------
local STATUS_TEXT = {
	answered = "",
	missed = "Missed",
	declined = "Declined",
	noanswer = "No answer",
	cancelled = "Cancelled",
}

local function buildApp(content: ScrollingFrame)
	local function callButton(row: Frame, userId: number, enabled: boolean, reason: string?)
		if enabled then
			local b = UI.button({ Text = "CALL", TextSize = 13, BackgroundColor3 = GREEN, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(58, 30), Parent = row })
			b.Activated:Connect(function()
				Calls.call(userId)
			end)
		else
			UI.label({ Text = reason or "", TextSize = 11, TextColor3 = colors.subtext, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(80, 30), Parent = row })
		end
	end

	local open
	open = function()
		Phone.clear(content)
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		if current then
			local banner = Phone.card(content, 50, nextOrder())
			banner.BackgroundColor3 = Color3.fromRGB(30, 140, 70)
			UI.label({ Text = "On a call with " .. current.otherName, Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, -70, 1, 0), Parent = banner })
			local back = UI.button({ Text = "OPEN", TextSize = 12, BackgroundColor3 = Color3.fromRGB(20, 90, 45), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(60, 28), Parent = banner })
			back.Activated:Connect(function()
				minimized = false
				render()
			end)
		end

		local tabs = UI.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 34), LayoutOrder = nextOrder(), Parent = content })
		for i, name in { "Recents", "Contacts" } do
			local b = UI.button({
				Text = name:upper(),
				TextSize = 13,
				BackgroundColor3 = if tab == name then colors.xp else colors.panelLight,
				Position = UDim2.new((i - 1) * 0.5, if i == 2 then 4 else 0, 0, 0),
				Size = UDim2.new(0.5, -4, 1, 0),
				Parent = tabs,
			})
			b.Activated:Connect(function()
				tab = name
				open()
			end)
		end

		if tab == "Recents" then
			if not recents then
				local ok, _, data = invoke("recents")
				if ok and type(data) == "table" then
					recents = data
				end
			end
			local list = recents or {}
			if #list == 0 then
				UI.label({ Text = "No calls yet. Call someone from Contacts or the player menu.", TextSize = 13, TextColor3 = colors.subtext, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 44), LayoutOrder = nextOrder(), Parent = content })
				return
			end
			for _, r in list do
				local row = Phone.card(content, 50, nextOrder())
				local missed = r.s == "missed"
				local arrow = if r.d == "in" then "↙" else "↗"
				UI.label({ Text = arrow, Font = UI.FONT_BLACK, TextSize = 18, TextColor3 = if missed then colors.danger elseif r.d == "in" then GREEN else colors.xp, Size = UDim2.fromOffset(20, 26), Parent = row })
				UI.label({ Text = tostring(r.n), Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = if missed then colors.danger else colors.text, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -110, 0, 16), Parent = row })
				local detail = (if r.d == "in" then "Incoming" else "Outgoing")
				local st = STATUS_TEXT[r.s] or ""
				if st ~= "" then
					detail = st
				elseif (r.dur or 0) > 0 then
					detail ..= "  ·  " .. clock(r.dur)
				end
				UI.label({ Text = detail .. "  ·  " .. UI.timeAgo(r.t or os.time()), TextSize = 11, TextColor3 = colors.subtext, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(22, 17), Size = UDim2.new(1, -110, 0, 14), Parent = row })
				local here = type(r.id) == "number" and inThisServer(r.id)
				callButton(row, r.id, here and not current, if current then "" else "Not here")
			end
			local clearButton = UI.button({ Text = "Clear recents", TextSize = 12, BackgroundColor3 = colors.panel, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = nextOrder(), Parent = content })
			clearButton.Activated:Connect(function()
				local ok = invoke("clearRecents")
				if ok then
					recents = {}
					open()
				end
			end)
		else
			local ok, message, data = invoke("contacts")
			if not ok or type(data) ~= "table" then
				UI.label({ Text = message or "Couldn't load contacts. Try again.", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = nextOrder(), Parent = content })
				return
			end
			if #data == 0 then
				UI.label({ Text = "Nobody else is in this server yet, and you have no friends added.", TextSize = 13, TextColor3 = colors.subtext, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, -20, 0, 44), LayoutOrder = nextOrder(), Parent = content })
				return
			end
			local lastGroup = ""
			for _, c in data do
				local group = if c.here and c.friend then "FRIENDS HERE" elseif c.here then "IN THIS SERVER" else "FRIENDS ELSEWHERE"
				if group ~= lastGroup then
					lastGroup = group
					UI.label({ Text = group, Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = nextOrder(), Parent = content })
				end
				local row = Phone.card(content, 50, nextOrder())
				local pic = UI.new("ImageLabel", { BackgroundColor3 = colors.panel, Size = UDim2.fromOffset(26, 26), Parent = row }, { UI.corner(13) })
				if c.userId > 0 then
					setHeadshot(pic, c.userId)
				end
				UI.label({ Text = tostring(c.name), Font = UI.FONT_BOLD, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -120, 0, 16), Parent = row })
				local sub = if c.username ~= "" then "@" .. c.username else ""
				if c.busy then
					sub ..= "  ·  On a call"
				end
				UI.label({ Text = sub, TextSize = 11, TextColor3 = colors.subtext, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(32, 17), Size = UDim2.new(1, -120, 0, 14), Parent = row })
				local enabled = c.here and c.canCall and not c.busy and not current
				local why = if not c.here then "Not in this server" elseif c.busy then "On a call" elseif current then "" else (c.reason or "Not taking calls")
				callButton(row, c.userId, enabled, why)
			end
		end
	end
	return open
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function addMenuAction()
	local module = script.Parent:FindFirstChild("Social")
	if not module then
		return
	end
	local ok, Social = pcall(require, module)
	if not ok or type(Social) ~= "table" or type(Social.addMenuAction) ~= "function" then
		return
	end
	Social.addMenuAction({
		id = "calls_call",
		label = "CALL",
		order = 19,
		visible = function(_target: Player)
			return current == nil
		end,
		run = function(target: Player)
			Calls.call(target.UserId)
		end,
	})
end

-- Tells the server whether Roblox voice chat is on for this player (client-only API).
local function reportVoice()
	local enabled = false
	local okService, service = pcall(function()
		return game:GetService("VoiceChatService")
	end)
	if okService and service then
		local ok, result = pcall(function()
			return (service :: VoiceChatService):IsVoiceEnabledForUserIdAsync(player.UserId)
		end)
		enabled = ok and result == true
	end
	invoke("voice", enabled)
end

function Calls.start()
	Phone.addApp({ id = APP_ID, label = "Calls", icon = "📞", color = GREEN }, buildApp)
	buildScreens()

	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		CallAction = remotes:WaitForChild("CallAction") :: RemoteFunction
		local CallEvent = remotes:WaitForChild("CallEvent") :: RemoteEvent
		CallEvent.OnClientEvent:Connect(onEvent)
		reportVoice()
		-- the audio API can create our AudioDeviceInput after we join
		player.DescendantAdded:Connect(function(d)
			if d:IsA("AudioDeviceInput") then
				task.wait(1)
				reportVoice()
			end
		end)
		local ok, _, snap = invoke("current")
		if ok and type(snap) == "table" then
			onEvent("state", snap)
		end
	end)

	task.spawn(addMenuAction)
end

return Calls
