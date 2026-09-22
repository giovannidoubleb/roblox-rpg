--[[
	The merchant's shop: buy/equip cosmetics and companions with gems, and
	pick which owned companions are active (capped by companion slots).
	Opens from the hub merchant NPC, or press "B" directly.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local MerchantController = {}

local player = Players.LocalPlayer

function MerchantController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Merchant"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 380, 0, 420)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Merchant (press B to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local gemsLabel = Instance.new("TextLabel")
	gemsLabel.Size = UDim2.new(1, -20, 0, 20)
	gemsLabel.Position = UDim2.new(0, 10, 0, 32)
	gemsLabel.BackgroundTransparency = 1
	gemsLabel.TextXAlignment = Enum.TextXAlignment.Left
	gemsLabel.Font = Enum.Font.GothamBold
	gemsLabel.TextSize = 13
	gemsLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
	gemsLabel.Parent = panel

	local cosmeticsHeader = Instance.new("TextLabel")
	cosmeticsHeader.Size = UDim2.new(1, -20, 0, 18)
	cosmeticsHeader.Position = UDim2.new(0, 10, 0, 56)
	cosmeticsHeader.BackgroundTransparency = 1
	cosmeticsHeader.TextXAlignment = Enum.TextXAlignment.Left
	cosmeticsHeader.Font = Enum.Font.GothamBold
	cosmeticsHeader.TextSize = 13
	cosmeticsHeader.TextColor3 = Color3.fromRGB(180, 180, 180)
	cosmeticsHeader.Text = "Cosmetics"
	cosmeticsHeader.Parent = panel

	local cosmeticsList = Instance.new("Frame")
	cosmeticsList.Position = UDim2.new(0, 10, 0, 76)
	cosmeticsList.Size = UDim2.new(1, -20, 0, 150)
	cosmeticsList.BackgroundTransparency = 1
	cosmeticsList.Parent = panel

	local cosmeticsLayout = Instance.new("UIListLayout")
	cosmeticsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cosmeticsLayout.Padding = UDim.new(0, 4)
	cosmeticsLayout.Parent = cosmeticsList

	local companionsHeader = Instance.new("TextLabel")
	companionsHeader.Size = UDim2.new(1, -20, 0, 18)
	companionsHeader.Position = UDim2.new(0, 10, 0, 234)
	companionsHeader.BackgroundTransparency = 1
	companionsHeader.TextXAlignment = Enum.TextXAlignment.Left
	companionsHeader.Font = Enum.Font.GothamBold
	companionsHeader.TextSize = 13
	companionsHeader.TextColor3 = Color3.fromRGB(180, 180, 180)
	companionsHeader.Text = "Companions"
	companionsHeader.Parent = panel

	local companionsList = Instance.new("Frame")
	companionsList.Position = UDim2.new(0, 10, 0, 254)
	companionsList.Size = UDim2.new(1, -20, 0, 150)
	companionsList.BackgroundTransparency = 1
	companionsList.Parent = panel

	local companionsLayout = Instance.new("UIListLayout")
	companionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	companionsLayout.Padding = UDim.new(0, 4)
	companionsLayout.Parent = companionsList

	local function buildRow(parent: Instance, text: string, buttonText: string, onClick: () -> ())
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 26)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		row.Parent = parent

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -70, 1, 0)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.BackgroundTransparency = 1
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.Gotham
		label.TextSize = 12
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Text = text
		label.Parent = row

		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 60, 0, 20)
		button.Position = UDim2.new(1, -64, 0, 3)
		button.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
		button.Text = buttonText
		button.Font = Enum.Font.GothamBold
		button.TextSize = 11
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Parent = row
		UiKit.RoundButton(button, 4)

		button.MouseButton1Click:Connect(onClick)
		return row
	end

	local function refresh(data)
		gemsLabel.Text = string.format("Gems: %d", data.Gems)

		for _, child in cosmeticsList:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for cosmeticId, def in Config.Cosmetics.Available do
			local owned = data.Cosmetics.Owned[cosmeticId] == true
			local equipped = data.Cosmetics.Equipped == cosmeticId
			local text = string.format("%s (%d gems)%s", def.Name, def.GemCost, equipped and " [worn]" or "")

			if owned then
				buildRow(cosmeticsList, text, equipped and "Unequip" or "Wear", function()
					Remotes.RequestEquipCosmetic:FireServer(equipped and "" or cosmeticId)
				end)
			else
				buildRow(cosmeticsList, text, "Buy", function()
					Remotes.RequestPurchaseCosmetic:FireServer(cosmeticId)
				end)
			end
		end

		for _, child in companionsList:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for companionId, def in Config.Companions.Available do
			local owned = data.Companions.Owned[companionId] == true
			local active = table.find(data.Companions.Active, companionId) ~= nil
			local text = string.format("%s (%d gems)%s", def.Name, def.GemCost, active and " [out]" or "")

			if owned then
				buildRow(companionsList, text, active and "Recall" or "Summon", function()
					local newActive = table.clone(data.Companions.Active)
					if active then
						local index = table.find(newActive, companionId)
						if index then
							table.remove(newActive, index)
						end
					else
						table.insert(newActive, companionId)
					end
					Remotes.RequestSetActiveCompanions:FireServer(newActive)
				end)
			else
				buildRow(companionsList, text, "Buy", function()
					Remotes.RequestPurchaseCompanion:FireServer(companionId)
				end)
			end
		end
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(refresh)
	Remotes.OpenMerchantPanel.OnClientEvent:Connect(function()
		panel.Visible = true
	end)

	ContextActionService:BindAction("ToggleMerchant", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.B)
end

return MerchantController
