--[[
	Shows a brief toast when the server awards loot. Rarity colors match the
	tiers from the design doc (Common white -> Legendary orange).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local LootController = {}

local player = Players.LocalPlayer

local RARITY_COLOR = {
	Common = Color3.fromRGB(255, 255, 255),
	Uncommon = Color3.fromRGB(70, 200, 90),
	Rare = Color3.fromRGB(70, 140, 230),
	Epic = Color3.fromRGB(170, 80, 230),
	Legendary = Color3.fromRGB(240, 150, 40),
}

function LootController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LootToasts"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local container = Instance.new("Frame")
	container.Name = "Toasts"
	container.AnchorPoint = Vector2.new(1, 0)
	container.Position = UDim2.new(1, -20, 0, 20)
	container.Size = UDim2.new(0, 220, 1, -20)
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.Parent = container

	Remotes.LootReceived.OnClientEvent:Connect(function(loot)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 30)
		label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		label.BackgroundTransparency = 0.2
		label.TextColor3 = RARITY_COLOR[loot.Rarity] or Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.Text = string.format("+ %s (%s)", loot.Name, loot.Rarity)
		label.Parent = container

		task.delay(3, function()
			local tween = TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1, BackgroundTransparency = 1 })
			tween:Play()
			tween.Completed:Wait()
			label:Destroy()
		end)
	end)
end

return LootController
