--[[
	First-10-seconds hook for a brand new player: a quick "Welcome" banner
	with rotating one-line tips, plus a glowing highlight + floating marker
	on the nearest enemy so there's an obvious, immediate thing to do
	instead of a blank field. Onboarding on Roblox lives or dies on whether
	someone finds something worth doing in the first few seconds, so this
	fires as soon as the character exists - no waiting on a full data
	round-trip beyond the one PlayerDataUpdated payload that already always
	arrives first.

	Shown at most once per player, ever: gated by the server-persisted
	HasOnboarded flag (PlayerDataService), confirmed back to the server via
	RequestMarkOnboarded once the sequence finishes.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Locale = require(script.Parent.Parent.Locale)
local UiKit = require(script.Parent.Parent.UiKit)

local OnboardingController = {}

local player = Players.LocalPlayer

local TIP_KEYS = { "WelcomeTip1", "WelcomeTip2", "WelcomeTip3" }
local TIP_INTERVAL = 2.6
local HIGHLIGHT_SECONDS = 14

local function findNearestEnemy(fromPosition: Vector3): Model?
	local closest, closestDistance = nil, math.huge
	for _, model in Workspace:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Tier") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model.PrimaryPart
			if humanoid and humanoid.Health > 0 and root then
				local distance = (root.Position - fromPosition).Magnitude
				if distance < closestDistance then
					closest, closestDistance = model, distance
				end
			end
		end
	end
	return closest
end

local function markNearestEnemy(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local enemy = findNearestEnemy(root.Position)
	if not enemy or not enemy.PrimaryPart then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 220, 90)
	highlight.OutlineTransparency = 0
	highlight.Parent = enemy

	local marker = Instance.new("BillboardGui")
	marker.Name = "OnboardingMarker"
	marker.Size = UDim2.new(0, 140, 0, 30)
	marker.StudsOffset = Vector3.new(0, 3.5, 0)
	marker.AlwaysOnTop = true
	marker.Parent = enemy.PrimaryPart

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.fromRGB(255, 220, 90)
	label.TextStrokeTransparency = 0.3
	label.Text = "⚔ ATTACK!"
	label.Parent = marker

	local pulse = TweenService:Create(
		highlight,
		TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ OutlineTransparency = 0.6 }
	)
	pulse:Play()

	local removed = false
	local function cleanup()
		if removed then
			return
		end
		removed = true
		pulse:Stop()
		highlight:Destroy()
		if marker.Parent then
			marker:Destroy()
		end
	end

	Debris:AddItem(highlight, HIGHLIGHT_SECONDS)
	task.delay(HIGHLIGHT_SECONDS, cleanup)

	-- Clears the marker the moment the player actually lands a hit, so it
	-- doesn't linger after it's done its job.
	local connection
	connection = Remotes.DamageDealt.OnClientEvent:Connect(function()
		cleanup()
		if connection then
			connection:Disconnect()
		end
	end)
end

local function playWelcomeBanner(onDone: () -> ())
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Onboarding"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 5
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 40)
	card.Size = UDim2.new(0, 420, 0, 76)
	card.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	card.BackgroundTransparency = 1
	card.Parent = screenGui
	UiKit.RoundPanel(card, 10)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0, 28)
	title.Position = UDim2.new(0, 10, 0, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(255, 220, 120)
	title.TextTransparency = 1
	title.Text = Locale.T("WelcomeTitle")
	title.Parent = card

	local tip = Instance.new("TextLabel")
	tip.Size = UDim2.new(1, -20, 0, 30)
	tip.Position = UDim2.new(0, 10, 0, 38)
	tip.BackgroundTransparency = 1
	tip.Font = Enum.Font.Gotham
	tip.TextSize = 15
	tip.TextColor3 = Color3.new(1, 1, 1)
	tip.TextTransparency = 1
	tip.TextWrapped = true
	tip.Parent = card

	TweenService:Create(card, TweenInfo.new(0.4), { BackgroundTransparency = 0.15 }):Play()
	TweenService:Create(title, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
	TweenService:Create(tip, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()

	task.spawn(function()
		for _, key in TIP_KEYS do
			tip.Text = Locale.T(key)
			task.wait(TIP_INTERVAL)
		end

		local fadeOut = TweenService:Create(card, TweenInfo.new(0.6), { BackgroundTransparency = 1 })
		TweenService:Create(title, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		TweenService:Create(tip, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		fadeOut:Play()
		fadeOut.Completed:Wait()
		screenGui:Destroy()
		onDone()
	end)
end

function OnboardingController.Init()
	local played = false

	local function runOnce(data)
		if played or data.HasOnboarded then
			return
		end
		played = true

		local character = player.Character or player.CharacterAdded:Wait()
		task.wait(0.5)

		markNearestEnemy(character)
		playWelcomeBanner(function()
			Remotes.RequestMarkOnboarded:FireServer()
		end)
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(runOnce)
end

return OnboardingController
