--[[
	Season track panel. Toggle with "P". Tiers unlock by character level
	(ordinary play advances it); claiming a reached tier's reward requires
	owning the Season Pass, enforced server-side.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local SeasonController = {}

local player = Players.LocalPlayer

function SeasonController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Season"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 320, 0, 340)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Season Pass (press P to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -20, 0, 18)
	statusLabel.Position = UDim2.new(0, 10, 0, 30)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 12
	statusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	statusLabel.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.new(0, 10, 0, 54)
	scroll.Size = UDim2.new(1, -20, 1, -64)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = scroll

	local function refresh(data)
		local hasPass = data.Passes.SeasonPass == true
		statusLabel.Text = hasPass and "Season Pass active" or "Season Pass required to claim rewards"

		for _, child in scroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		for tierIndex, tier in Config.Season.Tiers do
			local reached = data.Level >= tier.Level
			local claimed = data.SeasonClaimedTiers[tostring(tierIndex)] == true

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 26)
			row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
			row.Parent = scroll

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, -70, 1, 0)
			label.Position = UDim2.new(0, 8, 0, 0)
			label.BackgroundTransparency = 1
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Font = Enum.Font.Gotham
			label.TextSize = 12
			label.TextColor3 = reached and Color3.new(1, 1, 1) or Color3.fromRGB(120, 120, 120)
			label.Text = string.format("Lvl %d - %d gems", tier.Level, tier.Gems)
			label.Parent = row

			local button = Instance.new("TextButton")
			button.Size = UDim2.new(0, 60, 0, 20)
			button.Position = UDim2.new(1, -64, 0, 3)
			button.Font = Enum.Font.GothamBold
			button.TextSize = 11
			button.TextColor3 = Color3.new(1, 1, 1)
			button.Parent = row

			if claimed then
				button.Text = "Claimed"
				button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
			elseif reached and hasPass then
				button.Text = "Claim"
				button.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
			else
				button.Text = "Claim"
				button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
			end

			UiKit.RoundButton(button, 4)

			button.MouseButton1Click:Connect(function()
				Remotes.RequestClaimSeasonTier:FireServer(tierIndex)
			end)
		end
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(refresh)

	ContextActionService:BindAction("ToggleSeason", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.P)
end

return SeasonController
