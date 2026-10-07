-- CITY GRIND: Iron Box Gym client (sections 56, 69, 110, 120).
-- Draws the rep meter while you train, sends button presses (with the server
-- clock time of the press) and shows what the server awarded. The server
-- judges every rep; nothing here decides stats, XP or money.
-- Also adds the "Fitness" phone app and the pass / membership purchase panel.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local Phone = require(script.Parent:WaitForChild("Phone"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local GymConfig = require(shared:WaitForChild("GymConfig"))

local player = Players.LocalPlayer
local colors = UI.colors

local Gym = {}

local STATIONS = GymConfig.STATIONS
local PER_POINT = Config.STAT_XP_PER_POINT
local GOOD_COLOR = Color3.fromRGB(90, 220, 120)
local PERFECT_COLOR = Color3.fromRGB(255, 215, 70)

local remotes: Instance
local gui: ScreenGui

type Session = {
	kind: string,
	start: number,
	seed: number,
	goodReps: number,
	startedAt: number,
	streak: number,
}
local session: Session? = nil
local blockedUntil = 0
local raceState = "none"

-- widgets filled in by buildPanel()
local panel: Frame
local titleLabel: TextLabel
local repsLabel: TextLabel
local subLabel: TextLabel
local challengeLabel: TextLabel
local meter: Frame
local goodZone: Frame
local perfectZone: Frame
local marker: Frame
local feedback: TextLabel
local hintLabel: TextLabel
local statRows: { { frame: Frame, name: TextLabel, value: TextLabel, setFill: (number) -> () } } = {}
local fatigueText: TextLabel
local setFatigue: (number) -> ()
local fatigueFill: Frame
local racePanel: Frame
local raceLabel: TextLabel
local racePrimary: TextButton
local raceSecondary: TextButton
local raceBars: Frame
local setMyRace: (number) -> ()
local setTheirRace: (number) -> ()
local offerFrame: Frame
local offerBody: TextLabel
local offerCash: TextLabel
local offerPass: TextButton
local offerMember: TextButton

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function prettyStat(stat: string): string
	return (stat:gsub("(%l)(%u)", "%1 %2"))
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function currentFatigue(): number
	return GymConfig.currentFatigue(player:GetAttribute("GymFatigue") or 0, player:GetAttribute("GymFatigueAt") or 0, serverNow())
end

local function inputHint(): string
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Press A when the marker is in the green zone · B to leave"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Tap REP when the marker is in the green zone"
	end
	return "SPACE or CLICK when the marker is in the green zone · Backspace to leave"
end

local function popup(text: string, color: Color3, index: number)
	local label = UI.label({
		Text = text,
		Font = UI.FONT_BLACK,
		TextSize = 20,
		TextColor3 = color,
		TextStrokeTransparency = 0.4,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, (index - 1) * 150 - 40, 0, -6 - (index - 1) * 4),
		Size = UDim2.fromOffset(220, 24),
		ZIndex = 5,
		Parent = panel,
	})
	local tween = TweenService:Create(label, TweenInfo.new(1.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = label.Position - UDim2.fromOffset(0, 60),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	tween:Play()
	task.delay(1.35, label.Destroy, label)
end

local function flash(text: string, color: Color3)
	feedback.Text = text
	feedback.TextColor3 = color
	feedback.TextTransparency = 0
	feedback.TextStrokeTransparency = 0.3
	local scale = feedback:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = 0.7
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	local token = os.clock()
	feedback:SetAttribute("Token", token)
	task.delay(0.6, function()
		if feedback:GetAttribute("Token") == token then
			TweenService:Create(feedback, TweenInfo.new(0.3), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

---------------------------------------------------------------------------
-- Training panel
---------------------------------------------------------------------------
local function setProgress(progress: { any }?)
	if not progress then
		return
	end
	for i, row in statRows do
		local entry = progress[i]
		row.frame.Visible = entry ~= nil
		if entry then
			row.name.Text = string.format("%s  %d", prettyStat(entry.stat), entry.value)
			if entry.value >= 99 then
				row.value.Text = "MAX"
				row.setFill(1)
			else
				row.value.Text = string.format("%.1f / %d", entry.xp, PER_POINT)
				row.setFill(entry.xp / PER_POINT)
			end
		end
	end
end

local function setChallenge(ch: any)
	if not ch or not session or ch.station ~= session.kind then
		challengeLabel.Text = ""
		return
	end
	if ch.done then
		challengeLabel.Text = "Daily challenge done ✓"
		challengeLabel.TextColor3 = colors.cash
	else
		challengeLabel.Text = string.format("Daily: %d / %d", ch.progress, ch.target)
		challengeLabel.TextColor3 = colors.stamina
	end
end

local function updateFatigue()
	local f = currentFatigue()
	local eff = GymConfig.efficiency(f)
	setFatigue(f / 100)
	fatigueFill.BackgroundColor3 = if f <= GymConfig.FATIGUE_FREE then colors.stamina elseif eff > 0.5 then colors.accent else colors.danger
	if f <= GymConfig.FATIGUE_FREE then
		fatigueText.Text = string.format("Fatigue %d%%  ·  Gains 100%%", math.floor(f))
	else
		fatigueText.Text = string.format("Fatigue %d%%  ·  Gains %d%%  ·  rest to recover", math.floor(f), math.floor(eff * 100))
	end
end

local function buildPanel()
	panel = UI.new("Frame", {
		Name = "Training",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.08,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -48),
		Size = UDim2.fromOffset(380, 238),
		Visible = false,
		Parent = gui,
	}, { UI.corner(16), UI.stroke(colors.accent, 1.5, 0.4), UI.padding(12) })
	HUD.slot("bottomCenter", panel, 25)
	local scale = UI.new("UIScale", { Parent = panel })
	local function fit()
		local cam = Workspace.CurrentCamera
		if cam then
			-- the HUD slot already applies HUD.scale(); keep the same overall size as before
			scale.Scale = math.clamp(math.min(cam.ViewportSize.X / 420, cam.ViewportSize.Y / 520), 0.6, 1) / math.max(HUD.scale(), 0.1)
		end
	end
	fit()
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end

	titleLabel = UI.label({ Text = "TRAINING", Font = UI.FONT_BLACK, TextSize = 18, Size = UDim2.new(1, -90, 0, 20), Parent = panel })
	repsLabel = UI.label({ Text = "REPS 0", Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = colors.xp, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(90, 20), Parent = panel })
	subLabel = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(0.6, 0, 0, 16), Parent = panel })
	challengeLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 22), Size = UDim2.new(0.4, 0, 0, 16), Parent = panel })

	meter = UI.new("Frame", { Name = "Meter", BackgroundColor3 = Color3.fromRGB(40, 40, 50), ClipsDescendants = false, Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 30), Parent = panel }, { UI.corner(8) })
	goodZone = UI.new("Frame", { Name = "Good", BackgroundColor3 = GOOD_COLOR, Size = UDim2.fromScale(0.2, 1), Parent = meter }, { UI.corner(6) })
	perfectZone = UI.new("Frame", { Name = "Perfect", BackgroundColor3 = PERFECT_COLOR, Size = UDim2.fromScale(0.06, 1), ZIndex = 2, Parent = meter }, { UI.corner(4) })
	marker = UI.new("Frame", { Name = "Marker", BackgroundColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0, 5, 1, 10), Position = UDim2.fromScale(0, 0.5), ZIndex = 3, Parent = meter }, { UI.corner(2), UI.stroke(Color3.new(0, 0, 0), 1, 0.3) })
	feedback = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 26, TextTransparency = 1, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1.4), ZIndex = 4, Parent = meter }, { UI.new("UIScale") })

	hintLabel = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 80), Size = UDim2.new(1, 0, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = panel })

	for i = 1, 2 do
		local y = 100 + (i - 1) * 22
		local row = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 18), Parent = panel })
		local name = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.fromOffset(120, 18), Parent = row })
		local _, setFill = UI.bar({ Position = UDim2.fromOffset(124, 5), Size = UDim2.new(1, -214, 0, 8), Parent = row }, colors.xp)
		local value = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(84, 18), Parent = row })
		table.insert(statRows, { frame = row, name = name, value = value, setFill = setFill })
	end

	local fatigueBar
	fatigueBar, setFatigue = UI.bar({ Position = UDim2.fromOffset(0, 150), Size = UDim2.new(1, 0, 0, 6), Parent = panel }, colors.stamina)
	fatigueFill = fatigueBar:FindFirstChild("Fill") :: Frame
	fatigueText = UI.label({ Text = "", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 158), Size = UDim2.new(1, 0, 0, 14), Parent = panel })

	local repButton = UI.button({ Name = "Rep", Text = "REP", Font = UI.FONT_BLACK, TextSize = 20, BackgroundColor3 = colors.accent, Position = UDim2.fromOffset(0, 178), Size = UDim2.new(0.62, -4, 0, 36), Parent = panel })
	local leaveButton = UI.button({ Name = "Leave", Text = "LEAVE", Font = UI.FONT_BLACK, TextSize = 16, BackgroundColor3 = colors.panelLight, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 178), Size = UDim2.new(0.38, -4, 0, 36), Parent = panel })
	repButton.Activated:Connect(function()
		Gym.pressRep()
	end)
	leaveButton.Activated:Connect(function()
		Gym.leave()
	end)

	-- race box sits above the training panel
	racePanel = UI.new("Frame", {
		Name = "Race",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.08,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -14),
		Size = UDim2.new(1, 24, 0, 74),
		Visible = false,
		Parent = panel,
	}, { UI.corner(14), UI.stroke(Color3.fromRGB(80, 200, 255), 1.5, 0.3), UI.padding(10) })
	raceLabel = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 14, TextWrapped = true, Size = UDim2.new(1, -130, 0, 34), Parent = racePanel })
	racePrimary = UI.button({ Text = "RACE", Font = UI.FONT_BLACK, TextSize = 14, BackgroundColor3 = Color3.fromRGB(60, 160, 230), AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(120, 24), Parent = racePanel })
	raceSecondary = UI.button({ Text = "DECLINE", Font = UI.FONT_BOLD, TextSize = 13, BackgroundColor3 = colors.panelLight, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 28), Size = UDim2.fromOffset(120, 24), Parent = racePanel })
	raceBars = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, -130, 0, 16), Parent = racePanel })
	local _, setMine = UI.bar({ Size = UDim2.new(1, 0, 0, 6), Parent = raceBars }, colors.cash)
	local _, setTheirs = UI.bar({ Position = UDim2.fromOffset(0, 9), Size = UDim2.new(1, 0, 0, 6), Parent = raceBars }, colors.danger)
	setMyRace, setTheirRace = setMine, setTheirs

	local function racePrimaryAction()
		if raceState == "available" then
			remotes.GymRace:FireServer("invite")
		elseif raceState == "waiting" then
			remotes.GymRace:FireServer("cancel")
		elseif raceState == "invite" then
			remotes.GymRace:FireServer("accept")
		end
	end
	racePrimary.Activated:Connect(racePrimaryAction)
	raceSecondary.Activated:Connect(function()
		if raceState == "invite" then
			remotes.GymRace:FireServer("decline")
		end
	end)
	Gym.racePrimaryAction = racePrimaryAction
end

local function showRace(payload: any)
	raceState = payload.state
	local opp = tostring(payload.opponent or "")
	local keyHint = if UserInputService.KeyboardEnabled then " (R)" elseif UserInputService.GamepadEnabled then " (Y)" else ""
	racePanel.Visible = raceState ~= "none" and session ~= nil
	raceSecondary.Visible = raceState == "invite"
	racePrimary.Visible = raceState ~= "active"
	raceBars.Visible = raceState == "active"
	if raceState == "available" then
		raceLabel.Text = "🏁 " .. opp .. " is on the next treadmill. Race to " .. payload.target .. " good reps?"
		racePrimary.Text = "RACE" .. keyHint
	elseif raceState == "waiting" then
		raceLabel.Text = "Waiting for " .. opp .. " to accept..."
		racePrimary.Text = "CANCEL" .. keyHint
	elseif raceState == "invite" then
		raceLabel.Text = "🏁 " .. opp .. " challenges you! First to " .. payload.target .. " good reps."
		racePrimary.Text = "ACCEPT" .. keyHint
		raceSecondary.Text = "DECLINE"
	elseif raceState == "active" then
		local mine, theirs = payload.mine or 0, payload.theirs or 0
		raceLabel.Text = string.format("RACE  ·  You %d  —  %d %s  ·  first to %d", mine, theirs, opp, payload.target)
		setMyRace(mine / payload.target)
		setTheirRace(theirs / payload.target)
	end
end

---------------------------------------------------------------------------
-- Session start / stop
---------------------------------------------------------------------------
local animateWasEnabled = true

local function setAnimate(enabled: boolean)
	local character = player.Character
	if not character then
		return
	end
	local animate = character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		if not enabled then
			animateWasEnabled = animate.Enabled
			animate.Enabled = false
		elseif animateWasEnabled then
			animate.Enabled = true
		end
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not enabled and animator then
		-- freeze the default walk/idle so the server's training pose reads cleanly
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0.1)
		end
	end
end

local function bindInputs()
	ContextActionService:BindActionAtPriority("GymRep", function(_, state)
		if state == Enum.UserInputState.Begin then
			Gym.pressRep()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
	ContextActionService:BindActionAtPriority("GymLeave", function(_, state)
		if state == Enum.UserInputState.Begin then
			Gym.leave()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
	ContextActionService:BindActionAtPriority("GymRaceKey", function(_, state)
		if state == Enum.UserInputState.Begin and racePanel.Visible and racePrimary.Visible then
			Gym.racePrimaryAction()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.R, Enum.KeyCode.ButtonY)
end

local function unbindInputs()
	ContextActionService:UnbindAction("GymRep")
	ContextActionService:UnbindAction("GymLeave")
	ContextActionService:UnbindAction("GymRaceKey")
end

local function setPrompts(enabled: boolean)
	pcall(function()
		ProximityPromptService.Enabled = enabled
	end)
end

local function onStart(payload: any)
	local def = STATIONS[payload.kind]
	if not def then
		return
	end
	session = {
		kind = payload.kind,
		start = payload.start,
		seed = payload.seed,
		goodReps = payload.goodReps or 0,
		startedAt = os.clock(),
		streak = 0,
	}
	blockedUntil = os.clock() + 0.4
	titleLabel.Text = string.upper(def.label)
	titleLabel.TextColor3 = def.color
	local names = {}
	for _, entry in def.stats do
		table.insert(names, prettyStat(entry[1]))
	end
	subLabel.Text = "Trains " .. table.concat(names, " + ")
	repsLabel.Text = "REPS 0"
	hintLabel.Text = inputHint()
	goodZone.Size = UDim2.fromScale(def.good * 2, 1)
	perfectZone.Size = UDim2.fromScale(def.perfect * 2, 1)
	setProgress(payload.progress)
	setChallenge(payload.challenge)
	updateFatigue()
	raceState = "none"
	racePanel.Visible = false
	panel.Visible = true
	setAnimate(false)
	setPrompts(false)
	bindInputs()
end

local function onStop()
	if not session then
		return
	end
	session = nil
	panel.Visible = false
	racePanel.Visible = false
	raceState = "none"
	unbindInputs()
	setPrompts(true)
	setAnimate(true)
	Phone.refresh("Fitness")
end

function Gym.pressRep()
	local s = session
	if not s then
		return
	end
	local clock = os.clock()
	if clock < blockedUntil then
		return
	end
	local t = serverNow()
	-- judge locally only to pace the button; the server makes the real call
	local guess = GymConfig.judge(s.kind, t, s.start, s.seed, s.goodReps)
	blockedUntil = clock + (if guess == "miss" then GymConfig.MISS_COOLDOWN else GymConfig.MIN_REP_INTERVAL + 0.02)
	remotes.GymRep:FireServer(t)
end

function Gym.leave()
	if session then
		remotes.GymLeave:FireServer()
	end
end

local function onResult(payload: any)
	local s = session
	if not s then
		return
	end
	if payload.goodReps then
		s.goodReps = payload.goodReps
	end
	local q = payload.quality
	if q == "miss" then
		s.streak = 0
		flash("MISS", colors.danger)
		return
	elseif q == "tooFast" then
		flash("TOO FAST", colors.accent)
		return
	elseif q == "race" then
		setProgress(payload.progress)
		flash("RACE WON!", Color3.fromRGB(80, 200, 255))
		return
	end
	if q == "perfect" then
		s.streak += 1
		flash(if s.streak > 1 then "PERFECT x" .. s.streak else "PERFECT!", PERFECT_COLOR)
	else
		s.streak = 0
		flash("GOOD", GOOD_COLOR)
	end
	repsLabel.Text = "REPS " .. s.goodReps
	for i, gain in payload.gains or {} do
		popup(string.format("+%s %s XP", tostring(gain.amount), prettyStat(gain.stat)), if q == "perfect" then PERFECT_COLOR else GOOD_COLOR, i)
	end
	setProgress(payload.progress)
	setChallenge(payload.challenge)
	updateFatigue()
end

---------------------------------------------------------------------------
-- Purchase panel (door, outside kiosk, front desk)
---------------------------------------------------------------------------
local function buildOffer()
	offerFrame = UI.new("Frame", {
		Name = "GymOffer",
		BackgroundColor3 = colors.panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(340, 262),
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	}, { UI.corner(18), UI.stroke(Color3.fromRGB(230, 60, 45), 2, 0.2), UI.padding(16) })
	local scale = UI.new("UIScale", { Parent = offerFrame })
	local function fit()
		local cam = Workspace.CurrentCamera
		if cam then
			scale.Scale = math.clamp(math.min(cam.ViewportSize.X / 380, cam.ViewportSize.Y / 320), 0.6, 1)
		end
	end
	fit()
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
	UI.label({ Text = "IRON BOX GYM", Font = UI.FONT_BLACK, TextSize = 22, TextColor3 = Color3.fromRGB(255, 90, 70), Size = UDim2.new(1, 0, 0, 24), ZIndex = 10, Parent = offerFrame })
	offerBody = UI.label({ Text = "", TextSize = 14, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 52), ZIndex = 10, Parent = offerFrame })
	offerCash = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 16), ZIndex = 10, Parent = offerFrame })
	offerPass = UI.button({
		Text = string.format("DAY PASS  ·  $%d  ·  %d min", GymConfig.DAY_PASS_PRICE, GymConfig.DAY_PASS_SECONDS // 60),
		BackgroundColor3 = Color3.fromRGB(60, 160, 230),
		Position = UDim2.fromOffset(0, 108),
		Size = UDim2.new(1, 0, 0, 40),
		ZIndex = 10,
		Parent = offerFrame,
	})
	offerMember = UI.button({
		Text = string.format("MEMBERSHIP  ·  $%d  ·  forever", GymConfig.MEMBERSHIP_PRICE),
		BackgroundColor3 = Color3.fromRGB(230, 60, 45),
		Position = UDim2.fromOffset(0, 154),
		Size = UDim2.new(1, 0, 0, 40),
		ZIndex = 10,
		Parent = offerFrame,
	})
	local close = UI.button({ Text = "Not now", Font = UI.FONT_BOLD, TextSize = 14, BackgroundColor3 = colors.panelLight, Position = UDim2.fromOffset(0, 200), Size = UDim2.new(1, 0, 0, 30), ZIndex = 10, Parent = offerFrame })
	offerPass.Activated:Connect(function()
		remotes.GymBuy:FireServer("pass")
	end)
	offerMember.Activated:Connect(function()
		remotes.GymBuy:FireServer("member")
	end)
	close.Activated:Connect(function()
		offerFrame.Visible = false
		GuiService.SelectedObject = nil
	end)
	-- walking away closes it (checked 5x a second)
	local walkAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		walkAcc += dt
		if walkAcc < 0.2 then
			return
		end
		walkAcc = 0
		if offerFrame.Visible and offerFrame:GetAttribute("OpenedAt") and os.clock() - offerFrame:GetAttribute("OpenedAt") > 1 then
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local anchor = offerFrame:GetAttribute("Anchor") :: Vector3?
			if root and anchor and (root.Position - anchor).Magnitude > 24 then
				offerFrame.Visible = false
				GuiService.SelectedObject = nil
			end
		end
	end)
end

local function showOffer(payload: any)
	local member = player:GetAttribute("GymMember") == true
	local passUntil = player:GetAttribute("GymPassUntil") or 0
	local left = passUntil - serverNow()
	if member then
		offerBody.Text = "You're an Iron Box member. Walk right in and train any time."
	elseif left > 0 then
		offerBody.Text = string.format("Your day pass has %d min left. Buying another adds %d minutes.", math.ceil(left / 60), GymConfig.DAY_PASS_SECONDS // 60)
	elseif payload.where == "door" then
		offerBody.Text = "Your free trial is used up. Grab a day pass or go all in with a membership."
	else
		offerBody.Text = "Day passes and memberships. Members train forever for one price."
	end
	offerCash.Text = "You have " .. UI.formatCash(player:GetAttribute("Cash") or 0)
	offerPass.Visible = not member
	offerMember.Visible = not member
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	offerFrame:SetAttribute("Anchor", if root then root.Position else nil)
	offerFrame:SetAttribute("OpenedAt", os.clock())
	offerFrame.Visible = true
	if UserInputService.GamepadEnabled and not member then
		GuiService.SelectedObject = offerPass
	end
end

---------------------------------------------------------------------------
-- Fitness phone app
---------------------------------------------------------------------------
local function buildFitnessApp(content: ScrollingFrame)
	local busy = false
	local function row(parent: Instance, y: number, left: string, right: string, rightColor: Color3?)
		UI.label({ Text = left, Font = UI.FONT_BOLD, TextSize = 13, Position = UDim2.fromOffset(0, y), Size = UDim2.new(0.65, 0, 0, 16), Parent = parent })
		UI.label({ Text = right, Font = UI.FONT_BOLD, TextSize = 13, TextColor3 = rightColor or colors.text, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.new(0.35, 0, 0, 16), Parent = parent })
	end

	return function()
		if busy then
			return
		end
		busy = true
		local ok, data = pcall(function()
			return shared:WaitForChild("Remotes"):WaitForChild("GymGetProgress"):InvokeServer()
		end)
		busy = false
		if not ok or type(data) ~= "table" then
			if not content:FindFirstChild("Loaded") then
				Phone.clear(content)
				UI.label({ Text = "Loading your fitness data...", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
			end
			return
		end
		Phone.clear(content)
		UI.new("Folder", { Name = "Loaded", Parent = content })

		-- membership + fatigue
		local top = Phone.card(content, 112, 1)
		UI.label({ Text = "IRON BOX GYM", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = Color3.fromRGB(255, 90, 70), Size = UDim2.new(1, 0, 0, 16), Parent = top })
		local accessColor = if data.member then colors.cash elseif data.passLeft > 0 then colors.xp else colors.subtext
		UI.label({ Text = data.access, Font = UI.FONT_BLACK, TextSize = 16, TextColor3 = accessColor, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 20), Parent = top })
		local fatigueBar, setF = UI.bar({ Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 8), Parent = top }, colors.stamina)
		setF(data.fatigue / 100)
		local fill = fatigueBar:FindFirstChild("Fill") :: Frame
		fill.BackgroundColor3 = if data.efficiency >= 1 then colors.stamina elseif data.efficiency > 0.5 then colors.accent else colors.danger
		UI.label({ Text = string.format("Fatigue %d%%  ·  Gains %d%%", math.floor(data.fatigue), math.floor(data.efficiency * 100)), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 14), Parent = top })
		UI.label({ Text = string.format("Total reps %d  ·  Race wins %d", data.totalReps, data.raceWins), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 74), Size = UDim2.new(1, 0, 0, 14), Parent = top })

		-- daily challenge
		local ch = data.challenge
		local chCard = Phone.card(content, 112, 2)
		UI.label({ Text = "TODAY'S CHALLENGE", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = chCard })
		UI.label({ Text = ch.text, Font = UI.FONT_BOLD, TextSize = 14, TextWrapped = true, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 32), Parent = chCard })
		local _, setCh = UI.bar({ Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 8), Parent = chCard }, if ch.done then colors.cash else colors.stamina)
		setCh(ch.progress / ch.target)
		row(chCard, 66, if ch.done then "Completed ✓" else string.format("%d / %d reps", ch.progress, ch.target), string.format("$%d + %d XP", ch.cash, ch.xp), colors.cash)
		UI.label({ Text = string.format("New challenge in %dh %02dm", ch.resetsIn // 3600, (ch.resetsIn % 3600) // 60), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 0, 14), Parent = chCard })

		-- the nine stats with progress to the next point
		local perPoint = data.perPoint or PER_POINT
		local statsCard = Phone.card(content, 24 + #Config.STATS * 36, 3)
		UI.label({ Text = "ATTRIBUTES", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = statsCard })
		for i, stat in Config.STATS do
			local y = 22 + (i - 1) * 36
			local value = data.stats[stat] or 1
			local xp = data.statXP[stat] or 0
			row(statsCard, y, prettyStat(stat), tostring(value), colors.accent)
			local _, setStat = UI.bar({ Position = UDim2.fromOffset(0, y + 18), Size = UDim2.new(1, 0, 0, 6), Parent = statsCard }, colors.accent)
			setStat(value / 99)
			local _, setNext = UI.bar({ Position = UDim2.fromOffset(0, y + 26), Size = UDim2.new(0.62, 0, 0, 4), Parent = statsCard }, colors.xp)
			setNext(if value >= 99 then 1 else xp / perPoint)
			UI.label({
				Text = if value >= 99 then "MAX" else string.format("%.1f / %d to next", xp, perPoint),
				TextSize = 10,
				TextColor3 = colors.subtext,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, y + 22),
				Size = UDim2.new(0.36, 0, 0, 12),
				Parent = statsCard,
			})
		end

		-- getting there
		local nav = Phone.card(content, 64, 4)
		if player:GetAttribute("Interior") == GymConfig.INTERIOR then
			UI.label({ Text = "You're at the Iron Box right now.\nWalk up to any machine and press Train.", TextSize = 13, TextWrapped = true, Size = UDim2.fromScale(1, 1), Parent = nav })
		else
			local gps = UI.button({ Text = "📍  GPS to Iron Box Gym", BackgroundColor3 = Color3.fromRGB(60, 160, 230), Size = UDim2.fromScale(1, 1), Parent = nav })
			gps.Activated:Connect(function()
				Phone.setGPS("Iron Box Gym", data.gymPosition)
				Phone.setOpen(false)
			end)
		end
		local tip = Phone.card(content, 64, 5)
		UI.label({
			Text = string.format("First visit is free. Day pass $%d (%d min) or membership $%d. Perfect reps give 50%% more. Rest when fatigue climbs.", GymConfig.DAY_PASS_PRICE, GymConfig.DAY_PASS_SECONDS // 60, GymConfig.MEMBERSHIP_PRICE),
			TextSize = 11,
			TextColor3 = colors.subtext,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.fromScale(1, 1),
			Parent = tip,
		})
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local function setup()
	remotes = shared:WaitForChild("Remotes")
	gui = UI.new("ScreenGui", {
		Name = "CityGrindGym",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 3,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildPanel()
	buildOffer()

	local sessionRemote = remotes:WaitForChild("GymSession") :: RemoteEvent
	remotes:WaitForChild("GymRep")
	remotes:WaitForChild("GymLeave")
	remotes:WaitForChild("GymBuy")
	remotes:WaitForChild("GymRace")
	sessionRemote.OnClientEvent:Connect(function(kind: string, payload: any)
		if kind == "start" then
			onStart(payload)
		elseif kind == "stop" then
			onStop()
		elseif kind == "result" then
			onResult(payload)
		elseif kind == "race" then
			showRace(payload)
		elseif kind == "offer" then
			showOffer(payload)
		elseif kind == "bought" then
			offerFrame.Visible = false
			GuiService.SelectedObject = nil
			Phone.refresh("Fitness")
		end
	end)

	-- mouse clicks anywhere outside UI count as a rep press
	UserInputService.InputBegan:Connect(function(input, processed)
		if session and not processed and input.UserInputType == Enum.UserInputType.MouseButton1 then
			Gym.pressRep()
		end
	end)
	-- on touch-only devices the jump button leaves the station
	UserInputService.JumpRequest:Connect(function()
		local s = session
		if s and UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and os.clock() - s.startedAt > 1 then
			Gym.leave()
		end
	end)

	RunService.RenderStepped:Connect(function()
		local s = session
		if not s then
			return
		end
		local def = STATIONS[s.kind]
		marker.Position = UDim2.fromScale(GymConfig.meterPos(serverNow(), s.start, def.period), 0.5)
		local c = GymConfig.zoneCenter(s.seed, s.goodReps)
		goodZone.Position = UDim2.fromScale(c - def.good, 0)
		perfectZone.Position = UDim2.fromScale(c - def.perfect, 0)
		local resting = os.clock() < blockedUntil
		goodZone.BackgroundTransparency = if resting then 0.65 else 0
		perfectZone.BackgroundTransparency = if resting then 0.65 else 0
	end)

	-- fatigue recovers over time; keep the meter honest
	task.spawn(function()
		while true do
			task.wait(1)
			if session then
				updateFatigue()
			end
		end
	end)
	for _, attr in { "GymFatigue", "GymFatigueAt" } do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if session then
				updateFatigue()
			end
		end)
	end
	player.CharacterAdded:Connect(function()
		-- the server ends the set when the character dies; make sure the UI follows
		onStop()
	end)
	if player:GetAttribute("Training") and player:GetAttribute("Training") ~= "" then
		-- joined mid-set (shouldn't happen) — let the player out cleanly
		remotes.GymLeave:FireServer()
	end
end

function Gym.start()
	Phone.addApp({ id = "Fitness", label = "Fitness", icon = "💪", color = Color3.fromRGB(230, 70, 50) }, function(content: ScrollingFrame)
		return buildFitnessApp(content)
	end)
	task.spawn(setup)
end

return Gym
