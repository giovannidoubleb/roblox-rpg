--[[
	Builds the core HUD (health bar, level, XP bar, gems, ultimate meter)
	entirely from code and keeps it in sync with PlayerDataUpdated /
	UltimateMeterUpdated. No Studio-authored UI yet - this is the smallest
	thing that proves the data pipeline works end to end. Daily
	quests/streak/keys live in DailyController's own panel.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HudController = {}

local player = Players.LocalPlayer

local function bar(parent: Instance, name: string, fillColor: Color3, yOffset: number)
	local container = Instance.new("Frame")
	container.Name = name
	container.Size = UDim2.new(1, 0, 0, 18)
	container.Position = UDim2.new(0, 0, 0, yOffset)
	container.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	container.BorderSizePixel = 0
	container.Parent = parent

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Parent = container

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.Parent = container

	return container, fill, label
end

function HudController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Hud"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0, 1)
	root.Position = UDim2.new(0, 20, 1, -20)
	root.Size = UDim2.new(0, 260, 0, 112)
	root.BackgroundTransparency = 1
	root.Parent = screenGui

	local levelLabel = Instance.new("TextLabel")
	levelLabel.Name = "Level"
	levelLabel.Size = UDim2.new(1, 0, 0, 18)
	levelLabel.BackgroundTransparency = 1
	levelLabel.TextColor3 = Color3.new(1, 1, 1)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Left
	levelLabel.Font = Enum.Font.GothamBold
	levelLabel.TextSize = 15
	levelLabel.Parent = root

	local _, healthFill, healthLabel = bar(root, "Health", Color3.fromRGB(200, 60, 60), 20)
	local _, xpFill, xpLabel = bar(root, "Experience", Color3.fromRGB(80, 160, 230), 42)
	local _, ultimateFill, ultimateLabel = bar(root, "Ultimate", Color3.fromRGB(230, 190, 60), 64)

	local gemsLabel = Instance.new("TextLabel")
	gemsLabel.Name = "Gems"
	gemsLabel.Size = UDim2.new(1, 0, 0, 18)
	gemsLabel.Position = UDim2.new(0, 0, 0, 88)
	gemsLabel.BackgroundTransparency = 1
	gemsLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
	gemsLabel.TextXAlignment = Enum.TextXAlignment.Left
	gemsLabel.Font = Enum.Font.GothamBold
	gemsLabel.TextSize = 14
	gemsLabel.Parent = root

	local function onDataUpdated(data)
		levelLabel.Text = string.format("Level %d — %d keys", data.Level, data.Keys)
		gemsLabel.Text = string.format("💎 %d gems", data.Gems)

		local xpToNext = Config.GetXpToNextLevel(data.Level)
		local fraction = data.Level >= Config.Leveling.MaxLevel and 1 or math.clamp(data.Experience / xpToNext, 0, 1)
		xpFill.Size = UDim2.new(fraction, 0, 1, 0)
		xpLabel.Text = data.Level >= Config.Leveling.MaxLevel and "MAX LEVEL"
			or string.format("XP %d / %d", data.Experience, xpToNext)
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(onDataUpdated)

	Remotes.UltimateMeterUpdated.OnClientEvent:Connect(function(meter: number, meterMax: number)
		ultimateFill.Size = UDim2.new(math.clamp(meter / meterMax, 0, 1), 0, 1, 0)
		ultimateLabel.Text = meter >= meterMax and "ULTIMATE READY (R)" or string.format("Ultimate %d%%", math.floor(meter / meterMax * 100))
	end)

	local function trackHealth(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local function refresh()
			healthFill.Size = UDim2.new(humanoid.Health / humanoid.MaxHealth, 0, 1, 0)
			healthLabel.Text = string.format("HP %d / %d", math.floor(humanoid.Health), humanoid.MaxHealth)
		end
		humanoid.HealthChanged:Connect(refresh)
		humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh)
		refresh()
	end

	if player.Character then
		trackHealth(player.Character)
	end
	player.CharacterAdded:Connect(trackHealth)
end

return HudController
