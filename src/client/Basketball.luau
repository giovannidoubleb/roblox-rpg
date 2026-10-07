-- CITY GRIND: basketball controls and on-screen feedback.
-- With the ball: hold Click / R2 / Shoot to raise the shot meter and let go in
-- the green zone; Q / X / Pass passes. Without it: F / X / Steal near a ball handler.
-- The server decides whether anything goes in; this only sends button presses.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local remotes = shared:WaitForChild("Remotes")
local BallAction = remotes:WaitForChild("BallAction")
local BallFx = remotes:WaitForChild("BallFx")

local player = Players.LocalPlayer
local colors = UI.colors
local B = Config.Ball

local Basketball = {}

local gui: ScreenGui
local meter: Frame
local meterFill: Frame
local meterLabel: TextLabel
local callout: TextLabel
local scoreboard: Frame
local scoreText: TextLabel
local subText: TextLabel

local charging = false
local chargeStart = 0
local METER_FULL = B.PERFECT_RELEASE * 2 -- the green zone sits in the middle

---------------------------------------------------------------------------
-- Shot meter
---------------------------------------------------------------------------
local function buildMeter()
	meter = UI.new("Frame", {
		Name = "ShotMeter",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.2,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -64),
		Size = UDim2.fromOffset(240, 18),
		Visible = false,
		Parent = gui,
	}, { UI.corner(9), UI.stroke(Color3.new(1, 1, 1), 1.5, 0.4) })
	HUD.slot("bottomCenter", meter, 30)
	local zoneWidth = B.PERFECT_TOLERANCE * 2 / METER_FULL
	local goodWidth = B.RELEASE_WINDOW * 0.6 / METER_FULL
	UI.new("Frame", {
		BackgroundColor3 = Color3.fromRGB(80, 160, 80),
		BackgroundTransparency = 0.4,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(goodWidth * 2, 1),
		Parent = meter,
	})
	UI.new("Frame", {
		BackgroundColor3 = Color3.fromRGB(90, 255, 120),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(zoneWidth, 1),
		ZIndex = 2,
		Parent = meter,
	})
	meterFill = UI.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(0, 4, 1, 8),
		ZIndex = 3,
		Parent = meter,
	}, { UI.corner(2) })
	meterLabel = UI.label({
		Text = "",
		Font = UI.FONT_BLACK,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		Position = UDim2.fromOffset(0, -24),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = meter,
	})
end

local function releaseFeedback(held: number)
	local off = math.abs(held - B.PERFECT_RELEASE)
	if off <= B.PERFECT_TOLERANCE then
		meterLabel.Text = "PERFECT"
		meterLabel.TextColor3 = Color3.fromRGB(90, 255, 120)
	elseif off <= B.RELEASE_WINDOW * 0.6 then
		meterLabel.Text = if held < B.PERFECT_RELEASE then "SLIGHTLY EARLY" else "SLIGHTLY LATE"
		meterLabel.TextColor3 = colors.stamina
	else
		meterLabel.Text = if held < B.PERFECT_RELEASE then "EARLY" else "LATE"
		meterLabel.TextColor3 = colors.danger
	end
	task.delay(0.9, function()
		if not charging then
			meter.Visible = false
			meterLabel.Text = ""
		end
	end)
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local function onShoot(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		charging = true
		chargeStart = os.clock()
		meter.Visible = true
		meterLabel.Text = ""
		BallAction:FireServer("ShootStart")
	elseif (state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel) and charging then
		charging = false
		releaseFeedback(os.clock() - chargeStart)
		BallAction:FireServer("ShootRelease")
	end
	return Enum.ContextActionResult.Sink
end

local function onPass(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		BallAction:FireServer("Pass")
	end
	return Enum.ContextActionResult.Sink
end

local function onSteal(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		BallAction:FireServer("Steal")
	end
	return Enum.ContextActionResult.Sink
end

local stealBound = false
local function refreshBindings()
	if player:GetAttribute("HasBall") then
		ContextActionService:BindAction("CityShoot", onShoot, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
		ContextActionService:SetTitle("CityShoot", "Shoot")
		ContextActionService:SetPosition("CityShoot", UDim2.new(1, -95, 1, -95))
		ContextActionService:BindAction("CityPass", onPass, true, Enum.KeyCode.Q, Enum.KeyCode.ButtonX)
		ContextActionService:SetTitle("CityPass", "Pass")
		ContextActionService:SetPosition("CityPass", UDim2.new(1, -170, 1, -60))
	else
		ContextActionService:UnbindAction("CityShoot")
		ContextActionService:UnbindAction("CityPass")
		if charging then
			charging = false
			meter.Visible = false
		end
	end
end

-- The steal button only appears near someone dribbling.
local function updateStealBinding()
	local want = false
	if not player:GetAttribute("HasBall") then
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			for _, other in Players:GetPlayers() do
				if other ~= player and other:GetAttribute("HasBall") then
					local r = other.Character and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if r and (r.Position - root.Position).Magnitude < 14 then
						want = true
						break
					end
				end
			end
		end
	end
	if want and not stealBound then
		ContextActionService:BindAction("CitySteal", onSteal, true, Enum.KeyCode.F, Enum.KeyCode.ButtonX)
		ContextActionService:SetTitle("CitySteal", "Steal")
		ContextActionService:SetPosition("CitySteal", UDim2.new(1, -170, 1, -60))
		stealBound = true
	elseif not want and stealBound then
		ContextActionService:UnbindAction("CitySteal")
		stealBound = false
	end
end

---------------------------------------------------------------------------
-- Callouts and scoreboard
---------------------------------------------------------------------------
local function showCallout(text: string)
	callout.Text = text
	callout.TextTransparency = 0
	callout.TextStrokeTransparency = 0.2
	local scale = callout:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = 0.6
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	local token = os.clock()
	callout:SetAttribute("Token", token)
	task.delay(1.6, function()
		if callout:GetAttribute("Token") == token then
			TweenService:Create(callout, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

local function buildScoreboard()
	scoreboard = UI.new("Frame", {
		Name = "Scoreboard",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(260, 56),
		Visible = false,
		Parent = gui,
	}, { UI.corner(12), UI.padding(6) })
	HUD.slot("topCenter", scoreboard, 10)
	scoreText = UI.label({ Text = "", Font = UI.FONT_BLACK, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 26), Parent = scoreboard })
	subText = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 16), Parent = scoreboard })
end

local function nearestActiveCourt(): Model?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local best, bestDist = nil, 90
	for _, court in CollectionService:GetTagged("Court") do
		local state = court:GetAttribute("State")
		local center = court:GetAttribute("CourtCenter")
		if center and (state == "Playing" or state == "Countdown" or state == "Ended") then
			local d = (center - root.Position).Magnitude
			local mine = player:GetAttribute("InGame") == court:GetAttribute("DisplayName")
			if mine then
				return court
			elseif d < bestDist then
				best, bestDist = court, d
			end
		end
	end
	return best
end

local function updateScoreboard()
	local court = nearestActiveCourt()
	scoreboard.Visible = court ~= nil
	if not court then
		return
	end
	local state = court:GetAttribute("State")
	local home, away = court:GetAttribute("HomeScore") or 0, court:GetAttribute("AwayScore") or 0
	scoreText.Text = string.format("HOME  %d  –  %d  AWAY", home, away)
	if state == "Countdown" then
		subText.Text = string.format("%s starts in %d", court:GetAttribute("Mode") or "", court:GetAttribute("Countdown") or 0)
	elseif state == "Ended" then
		subText.Text = "Final"
	elseif court:GetAttribute("Overtime") then
		subText.Text = "Next bucket wins"
	else
		local t = court:GetAttribute("TimeLeft") or 0
		local team = player:GetAttribute("Team")
		subText.Text = string.format("%d:%02d%s", t // 60, t % 60, if team then "   ·   You: " .. string.upper(team) else "")
	end
end

---------------------------------------------------------------------------
-- Dunk: the server says jump, the client (which owns its character) jumps.
---------------------------------------------------------------------------
local function dunkJump(rim: Vector3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end
	local toRim = Vector3.new(rim.X - root.Position.X, 0, rim.Z - root.Position.Z)
	local stopShort = if toRim.Magnitude > 1.5 then toRim - toRim.Unit * 1.2 else Vector3.zero
	local rise = math.max(4, rim.Y - root.Position.Y - 1)
	local up = math.sqrt(2 * workspace.Gravity * rise)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = stopShort / (up / workspace.Gravity) + Vector3.new(0, up, 0)
end

function Basketball.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindBasketball",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 3,
		Parent = player:WaitForChild("PlayerGui"),
	})
	buildMeter()
	buildScoreboard()
	callout = UI.label({
		Name = "Callout",
		Text = "",
		Font = UI.FONT_BLACK,
		TextSize = 54,
		TextColor3 = Color3.fromRGB(255, 210, 60),
		TextStrokeColor3 = Color3.fromRGB(60, 20, 0),
		TextStrokeTransparency = 1,
		TextTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.32),
		Size = UDim2.new(1, 0, 0, 70),
		Parent = gui,
	}, { UI.new("UIScale", {}) })

	player:GetAttributeChangedSignal("HasBall"):Connect(refreshBindings)
	refreshBindings()

	BallFx.OnClientEvent:Connect(function(kind: string, arg: any)
		if kind == "Callout" and type(arg) == "string" then
			showCallout(arg)
		elseif kind == "Dunk" and typeof(arg) == "Vector3" then
			dunkJump(arg)
		end
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		if charging then
			local t = (os.clock() - chargeStart) / METER_FULL
			meterFill.Position = UDim2.fromScale(math.clamp(t, 0, 1), 0.5)
		end
		accumulator += dt
		if accumulator >= 0.25 then
			accumulator = 0
			updateStealBinding()
			updateScoreboard()
		end
	end)
end

return Basketball
