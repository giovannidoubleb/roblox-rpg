--[[
	Daily quest list, streak, and login-bonus claim button. Toggle with "J".
	Keys are shown here too (they're also in the main HUD line) since this
	is the natural place to check "how much daily stuff is left".
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local DailyController = {}

local player = Players.LocalPlayer

local function findQuestDef(id: string)
	for _, questDef in Config.Daily.QuestPool do
		if questDef.Id == id then
			return questDef
		end
	end
	return nil
end

function DailyController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Daily"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -20, 0.5, 0)
	panel.Size = UDim2.new(0, 300, 0, 260)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Daily (press J to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local streakLabel = Instance.new("TextLabel")
	streakLabel.Size = UDim2.new(1, -20, 0, 20)
	streakLabel.Position = UDim2.new(0, 10, 0, 32)
	streakLabel.BackgroundTransparency = 1
	streakLabel.TextXAlignment = Enum.TextXAlignment.Left
	streakLabel.Font = Enum.Font.Gotham
	streakLabel.TextSize = 13
	streakLabel.TextColor3 = Color3.fromRGB(230, 190, 60)
	streakLabel.Parent = panel

	local claimButton = Instance.new("TextButton")
	claimButton.Size = UDim2.new(1, -20, 0, 28)
	claimButton.Position = UDim2.new(0, 10, 0, 54)
	claimButton.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
	claimButton.Text = "Claim Daily Login"
	claimButton.Font = Enum.Font.GothamBold
	claimButton.TextSize = 13
	claimButton.TextColor3 = Color3.new(1, 1, 1)
	claimButton.Parent = panel
	UiKit.RoundButton(claimButton)

	claimButton.MouseButton1Click:Connect(function()
		Remotes.ClaimDailyLogin:FireServer()
	end)

	local questList = Instance.new("Frame")
	questList.Position = UDim2.new(0, 10, 0, 92)
	questList.Size = UDim2.new(1, -20, 1, -102)
	questList.BackgroundTransparency = 1
	questList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = questList

	local function refresh(data)
		streakLabel.Text = string.format("🔥 Streak: %d days   🔑 Keys: %d / %d", data.Streak, data.Keys, Config.Daily.KeysPerDay)

		for _, child in questList:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		for _, quest in data.DailyQuests do
			local questDef = findQuestDef(quest.Id)
			if questDef then
				local label = Instance.new("TextLabel")
				label.Size = UDim2.new(1, 0, 0, 20)
				label.BackgroundTransparency = 1
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.Font = Enum.Font.Gotham
				label.TextSize = 13
				label.TextColor3 = quest.Completed and Color3.fromRGB(100, 220, 120) or Color3.new(1, 1, 1)
				label.Text = string.format(
					"%s %s (%d/%d)",
					quest.Completed and "✓" or "•",
					questDef.Description,
					quest.Progress,
					questDef.Target
				)
				label.Parent = questList
			end
		end
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(refresh)
	Remotes.OpenDailyPanel.OnClientEvent:Connect(function()
		panel.Visible = true
	end)

	ContextActionService:BindAction("ToggleDaily", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.J)
end

return DailyController
