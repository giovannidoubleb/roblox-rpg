--[[
	Skill point allocation panel. Toggle with "K". One point per level-up,
	spent into Damage/Health/CritChance; Respec refunds everything if you
	have a Stat Respec Token.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Locale = require(script.Parent.Parent.Locale)
local UiKit = require(script.Parent.Parent.UiKit)

local SkillController = {}

local player = Players.LocalPlayer

local STAT_ORDER = { "Damage", "Health", "CritChance" }
local STAT_LABEL = {
	Damage = string.format("Damage (+%d per point)", Config.SkillTree.DamagePerPoint),
	Health = string.format("Max Health (+%d per point)", Config.SkillTree.HealthPerPoint),
	CritChance = string.format("Crit Chance (+%d%% per point)", Config.SkillTree.CritChancePerPoint * 100),
}

function SkillController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Skills"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 320, 0, 260)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = Locale.T("SkillsTitle")
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local pointsLabel = Instance.new("TextLabel")
	pointsLabel.Size = UDim2.new(1, -20, 0, 20)
	pointsLabel.Position = UDim2.new(0, 10, 0, 32)
	pointsLabel.BackgroundTransparency = 1
	pointsLabel.TextXAlignment = Enum.TextXAlignment.Left
	pointsLabel.Font = Enum.Font.GothamBold
	pointsLabel.TextSize = 14
	pointsLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
	pointsLabel.Parent = panel

	local rows: { [string]: { Value: TextLabel } } = {}

	for i, statName in STAT_ORDER do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -20, 0, 30)
		row.Position = UDim2.new(0, 10, 0, 58 + (i - 1) * 36)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		row.Parent = panel

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -100, 1, 0)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.BackgroundTransparency = 1
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.Gotham
		label.TextSize = 12
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Text = STAT_LABEL[statName]
		label.Parent = row

		local value = Instance.new("TextLabel")
		value.Size = UDim2.new(0, 30, 1, 0)
		value.Position = UDim2.new(1, -68, 0, 0)
		value.BackgroundTransparency = 1
		value.Font = Enum.Font.GothamBold
		value.TextSize = 14
		value.TextColor3 = Color3.new(1, 1, 1)
		value.Text = "0"
		value.Parent = row

		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 30, 0, 24)
		button.Position = UDim2.new(1, -34, 0, 3)
		button.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
		button.Text = "+"
		button.Font = Enum.Font.GothamBold
		button.TextSize = 16
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Parent = row
		UiKit.RoundButton(button, 4)

		button.MouseButton1Click:Connect(function()
			Remotes.RequestAllocateSkill:FireServer(statName)
		end)

		rows[statName] = { Value = value }
	end

	local respecButton = Instance.new("TextButton")
	respecButton.Size = UDim2.new(1, -20, 0, 28)
	respecButton.Position = UDim2.new(0, 10, 1, -38)
	respecButton.BackgroundColor3 = Color3.fromRGB(150, 70, 70)
	respecButton.Text = Locale.T("RespecButton")
	respecButton.Font = Enum.Font.GothamBold
	respecButton.TextSize = 12
	respecButton.TextColor3 = Color3.new(1, 1, 1)
	respecButton.Parent = panel
	UiKit.RoundButton(respecButton)

	respecButton.MouseButton1Click:Connect(function()
		Remotes.RequestRespecSkills:FireServer()
	end)

	local function refresh(data)
		pointsLabel.Text = string.format(Locale.T("UnspentPoints"), data.SkillPoints)
		for statName, row in rows do
			row.Value.Text = tostring(data.AllocatedSkills[statName])
		end
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(refresh)
	Locale.OnChanged(function()
		title.Text = Locale.T("SkillsTitle")
		respecButton.Text = Locale.T("RespecButton")
	end)

	ContextActionService:BindAction("ToggleSkills", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.K)
end

return SkillController
