--[[
	Zone travel menu. Toggle with "M". Lists zones you've discovered by
	physically reaching their shrine; Travel instantly warps you there if
	you own the Fast Travel pass or have a Zone Skip Key (the server is the
	one that actually enforces that - this just sends the request).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local ZoneController = {}

local player = Players.LocalPlayer

function ZoneController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Zones"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 300, 0, 160)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Travel (press M to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local list = Instance.new("Frame")
	list.Position = UDim2.new(0, 10, 0, 36)
	list.Size = UDim2.new(1, -20, 1, -46)
	list.BackgroundTransparency = 1
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	local function refresh(data)
		for _, child in list:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		for zoneName, zoneDef in Config.Zones do
			local discovered = data.DiscoveredZones[zoneName] == true

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 26)
			row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
			row.Parent = list

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(1, -70, 1, 0)
			label.Position = UDim2.new(0, 8, 0, 0)
			label.BackgroundTransparency = 1
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Font = Enum.Font.Gotham
			label.TextSize = 12
			label.TextColor3 = discovered and Color3.new(1, 1, 1) or Color3.fromRGB(120, 120, 120)
			label.Text = discovered and zoneDef.DisplayName or (zoneDef.DisplayName .. " (undiscovered)")
			label.Parent = row

			local button = Instance.new("TextButton")
			button.Size = UDim2.new(0, 60, 0, 20)
			button.Position = UDim2.new(1, -64, 0, 3)
			button.BackgroundColor3 = discovered and Color3.fromRGB(70, 130, 200) or Color3.fromRGB(60, 60, 60)
			button.Text = "Travel"
			button.Font = Enum.Font.GothamBold
			button.TextSize = 11
			button.TextColor3 = Color3.new(1, 1, 1)
			button.Parent = row
			UiKit.RoundButton(button, 4)

			button.MouseButton1Click:Connect(function()
				if discovered then
					Remotes.RequestZoneTravel:FireServer(zoneName)
				end
			end)
		end
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(refresh)

	ContextActionService:BindAction("ToggleZones", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.M)
end

return ZoneController
