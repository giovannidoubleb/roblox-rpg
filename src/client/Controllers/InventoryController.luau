--[[
	A minimal inventory panel: toggle with "I", lists everything in
	Inventory with an Equip button, and shows what's currently equipped.
	No drag-and-drop or icons yet - this proves the equip pipeline works.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local ItemDatabase = require(ReplicatedStorage.Shared.Modules.ItemDatabase)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local InventoryController = {}

local RARITY_RANK = {}
for index, rarity in Config.RarityOrder do
	RARITY_RANK[rarity] = index
end

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
	UiKit.RoundPanel(panel)

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
	equippedLabel.Size = UDim2.new(1, -20, 0, 58)
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
	scroll.Position = UDim2.new(0, 10, 0, 94)
	scroll.Size = UDim2.new(1, -20, 1, -104)
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

	-- Common/Uncommon items have exactly one stat; Rare+ sustain alternatives
	-- (Thirsting Blade, Bulwark Plating, ...) have two, so this builds a list
	-- instead of returning on the first match.
	local function describeItemStat(item)
		local parts = {}
		if item.DamageBonus then
			table.insert(parts, string.format("+%d Dmg", item.DamageBonus))
		end
		if item.HealthBonus then
			table.insert(parts, string.format("+%d HP", item.HealthBonus))
		end
		if item.CritChanceBonus then
			table.insert(parts, string.format("+%d%% Crit", math.floor(item.CritChanceBonus * 100 + 0.5)))
		end
		if item.LifestealPercent then
			table.insert(parts, string.format("+%d%% Lifesteal", math.floor(item.LifestealPercent * 100 + 0.5)))
		end
		if item.DamageReductionPercent then
			table.insert(parts, string.format("+%d%% Dmg Reduction", math.floor(item.DamageReductionPercent * 100 + 0.5)))
		end
		if item.CooldownReductionPercent then
			table.insert(parts, string.format("+%d%% Cooldown Reduction", math.floor(item.CooldownReductionPercent * 100 + 0.5)))
		end
		return table.concat(parts, ", ")
	end

	local function describeEquipped(equipped, inventory)
		local parts = {}
		for _, slot in { "Weapon", "Armor", "Trinket" } do
			local instanceId = equipped[slot]
			local item = instanceId and inventory[instanceId] and ItemDatabase.Items[inventory[instanceId]]
			if item then
				table.insert(parts, string.format("%s: %s (%s)", slot, item.Name, describeItemStat(item)))
			else
				table.insert(parts, slot .. ": (empty)")
			end
		end
		return table.concat(parts, "\n")
	end

	local hasAutoSort = false
	Remotes.PlayerDataUpdated.OnClientEvent:Connect(function(data)
		hasAutoSort = data.Passes.AutoSort == true
	end)

	local function refresh(payload)
		equippedLabel.Text = describeEquipped(payload.Equipped, payload.Inventory)

		for _, child in scroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local entries = {}
		for instanceId, itemId in payload.Inventory do
			table.insert(entries, { InstanceId = instanceId, ItemId = itemId })
		end

		if hasAutoSort then
			table.sort(entries, function(a, b)
				local itemA, itemB = ItemDatabase.Items[a.ItemId], ItemDatabase.Items[b.ItemId]
				local rankA, rankB = RARITY_RANK[itemA.Rarity] or 0, RARITY_RANK[itemB.Rarity] or 0
				if rankA ~= rankB then
					return rankA > rankB
				end
				return itemA.Name < itemB.Name
			end)
		end

		for _, entry in entries do
			local instanceId, itemId = entry.InstanceId, entry.ItemId
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
				local stat = describeItemStat(item)
				label.Text = string.format(
					"%s [%s] %s%s",
					item.Name,
					item.Slot,
					stat,
					isEquipped and " (equipped)" or ""
				)
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
				UiKit.RoundButton(button, 4)

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
