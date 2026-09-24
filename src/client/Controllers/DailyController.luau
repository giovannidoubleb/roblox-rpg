--[[
	Daily quest list, streak, and login-bonus claim button. Toggle with "J".
	Keys are shown here too (they're also in the main HUD line) since this
	is the natural place to check "how much daily stuff is left". Auto-opens
	once per session, shortly after spawning, if today's login bonus hasn't
	been claimed yet - a reason-to-come-back reward only works if the player
	actually sees it, rather than needing to remember to press J.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Locale = require(script.Parent.Parent.Locale)
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
	panel.Size = UDim2.new(0, 300, 0, 300)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = Locale.T("DailyTitle")
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

	-- Streak pip track: one pip per day of the reward ladder, filled up to
	-- the current streak and highlighted on today's slot - a glance shows
	-- "how far along" instead of just a number.
	local pipCount = #Config.Daily.StreakRewardGems
	local pipTrack = Instance.new("Frame")
	pipTrack.Position = UDim2.new(0, 10, 0, 54)
	pipTrack.Size = UDim2.new(1, -20, 0, 26)
	pipTrack.BackgroundTransparency = 1
	pipTrack.Parent = panel

	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.Padding = UDim.new(0, 4)
	pipLayout.Parent = pipTrack

	local pips: { Frame } = {}
	for i = 1, pipCount do
		local pip = Instance.new("Frame")
		pip.Size = UDim2.new(0, (280 - (pipCount - 1) * 4) / pipCount, 1, 0)
		pip.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		pip.LayoutOrder = i
		pip.Parent = pipTrack
		UiKit.RoundButton(pip, 4)

		local pipLabel = Instance.new("TextLabel")
		pipLabel.Size = UDim2.new(1, 0, 1, 0)
		pipLabel.BackgroundTransparency = 1
		pipLabel.Font = Enum.Font.GothamBold
		pipLabel.TextSize = 11
		pipLabel.TextColor3 = Color3.new(1, 1, 1)
		pipLabel.Text = tostring(i)
		pipLabel.Parent = pip

		pips[i] = pip
	end

	local claimButton = Instance.new("TextButton")
	claimButton.Size = UDim2.new(1, -20, 0, 28)
	claimButton.Position = UDim2.new(0, 10, 0, 88)
	claimButton.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
	claimButton.Text = Locale.T("ClaimDailyButton")
	claimButton.Font = Enum.Font.GothamBold
	claimButton.TextSize = 13
	claimButton.TextColor3 = Color3.new(1, 1, 1)
	claimButton.Parent = panel
	UiKit.RoundButton(claimButton)

	claimButton.MouseButton1Click:Connect(function()
		Remotes.ClaimDailyLogin:FireServer()
	end)

	local questList = Instance.new("Frame")
	questList.Position = UDim2.new(0, 10, 0, 126)
	questList.Size = UDim2.new(1, -20, 1, -136)
	questList.BackgroundTransparency = 1
	questList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = questList

	local lastClaimDate = ""

	local function refresh(data)
		lastClaimDate = data.LastClaimDate
		streakLabel.Text = "🔥 " .. string.format(Locale.T("StreakLabel"), data.Streak, data.Keys, Config.Daily.KeysPerDay)

		for i, pip in pips do
			if i <= data.Streak then
				pip.BackgroundColor3 = Color3.fromRGB(230, 190, 60)
			elseif i == data.Streak + 1 then
				pip.BackgroundColor3 = Color3.fromRGB(80, 100, 130)
			else
				pip.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
			end
		end

		local today = os.date("!%Y-%m-%d")
		claimButton.Text = data.LastClaimDate == today and "✓" or Locale.T("ClaimDailyButton")
		claimButton.BackgroundColor3 = data.LastClaimDate == today and Color3.fromRGB(60, 90, 60) or Color3.fromRGB(70, 130, 200)

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

	Locale.OnChanged(function()
		title.Text = Locale.T("DailyTitle")
		claimButton.Text = lastClaimDate == os.date("!%Y-%m-%d") and "✓" or Locale.T("ClaimDailyButton")
	end)

	-- Auto-prompt once per session, a couple of seconds after spawn, if
	-- today's bonus is still unclaimed - a proactive nudge rather than
	-- relying on the player to remember to press J.
	task.spawn(function()
		if player.Character then
			task.wait(3)
		else
			player.CharacterAdded:Wait()
			task.wait(3)
		end
		if lastClaimDate ~= os.date("!%Y-%m-%d") then
			panel.Visible = true
		end
	end)

	ContextActionService:BindAction("ToggleDaily", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.J)
end

return DailyController
