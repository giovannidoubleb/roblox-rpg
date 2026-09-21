--[[
	A minimal inventory panel: toggle with "I", lists everything in
	Inventory with an Equip button, and shows what's currently equipped.
	No drag-and-drop or icons yet - this proves the equip pipeline works.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemDatabase = require(ReplicatedStorage.Shared.Modules.ItemDatabase)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local InventoryController = {}

local player = Players.LocalPlayer

local RARITY_COLOR = {
	Common = Color3.fromRGB(255, 255, 255),
	Uncommon = Color3.fromRGB(70, 200, 90),
	Rare = Color3.fromRGB(70, 140, 230),
	Epic = Color3.fromRGB(170, 80, 230),
	Legendary = Color3.fromRGB(240, 150, 40),
}

function InventoryController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Inventory"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 340, 0, 400)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Inventory (press I to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local equippedLabel = Instance.new("TextLabel")
	equippedLabel.Name = "Equipped"
	equippedLabel.Size = UDim2.new(1, -20, 0, 50)
	equippedLabel.Position = UDim2.new(0, 10, 0, 32)
	equippedLabel.BackgroundTransparency = 1
	equippedLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	equippedLabel.Font = Enum.Font.Gotham
	equippedLabel.TextSize = 13
	equippedLabel.TextXAlignment = Enum.TextXAlignment.Left
	equippedLabel.TextYAlignment = Enum.TextYAlignment.Top
	equippedLabel.TextWrapped = true
	equippedLabel.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Items"
	scroll.Position = UDim2.new(0, 10, 0, 86)
	scroll.Size = UDim2.new(1, -20, 1, -96)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.Parent = panel

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = scroll

	local function describeEquipped(equipped)
		local parts = {}
		for _, slot in { "Weapon", "Armor", "Trinket" } do
			local instanceId = equipped[slot]
			if instanceId then
				table.insert(parts, slot .. ": (equipped)")
			else
				table.insert(parts, slot .. ": (empty)")
			end
		end
		return table.concat(parts, "   ")
	end

	local function refresh(payload)
		equippedLabel.Text = describeEquipped(payload.Equipped)

		for _, child in scroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		for instanceId, itemId in payload.Inventory do
			local item = ItemDatabase.Items[itemId]
			if item then
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 30)
				row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
				row.Parent = scroll

				local isEquipped = payload.Equipped[item.Slot] == instanceId

				local label = Instance.new("TextLabel")
				label.Size = UDim2.new(1, -70, 1, 0)
				label.Position = UDim2.new(0, 8, 0, 0)
				label.BackgroundTransparency = 1
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.Font = Enum.Font.Gotham
				label.TextSize = 13
				label.TextColor3 = RARITY_COLOR[item.Rarity] or Color3.new(1, 1, 1)
				label.Text = string.format("%s [%s]%s", item.Name, item.Slot, isEquipped and " (equipped)" or "")
				label.Parent = row

				local button = Instance.new("TextButton")
				button.Size = UDim2.new(0, 60, 0, 24)
				button.Position = UDim2.new(1, -64, 0, 3)
				button.BackgroundColor3 = isEquipped and Color3.fromRGB(60, 60, 60) or Color3.fromRGB(70, 130, 200)
				button.Text = isEquipped and "Equipped" or "Equip"
				button.Font = Enum.Font.GothamBold
				button.TextSize = 12
				button.TextColor3 = Color3.new(1, 1, 1)
				button.AutoButtonColor = not isEquipped
				button.Parent = row

				button.MouseButton1Click:Connect(function()
					if not isEquipped then
						Remotes.EquipItem:FireServer(instanceId)
					end
				end)
			end
		end
	end

	Remotes.InventoryUpdated.OnClientEvent:Connect(refresh)

	ContextActionService:BindAction("ToggleInventory", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.I)
end

return InventoryController
