--[[
	Crafting panel. Toggle with "C". Lists the fixed recipe ladder (4
	unequipped items of a rarity -> 1 guaranteed item of the next rarity
	up) and shows the pending timer while one's in progress.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local CraftingController = {}

local player = Players.LocalPlayer

function CraftingController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Crafting"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 340, 0, 280)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Crafting (press C to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -20, 0, 20)
	statusLabel.Position = UDim2.new(0, 10, 0, 32)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 13
	statusLabel.TextColor3 = Color3.fromRGB(230, 190, 60)
	statusLabel.Text = "No craft in progress."
	statusLabel.Parent = panel

	for i, recipe in Config.Crafting.Recipes do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -20, 0, 34)
		row.Position = UDim2.new(0, 10, 0, 58 + (i - 1) * 40)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		row.Parent = panel

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -80, 1, 0)
		label.Position = UDim2.new(0, 8, 0, 0)
		label.BackgroundTransparency = 1
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.Gotham
		label.TextSize = 12
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Text = string.format("%d x %s -> 1 %s", recipe.ConsumeCount, recipe.ConsumeRarity, recipe.ResultRarity)
		label.Parent = row

		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 64, 0, 24)
		button.Position = UDim2.new(1, -70, 0, 5)
		button.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
		button.Text = "Craft"
		button.Font = Enum.Font.GothamBold
		button.TextSize = 12
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Parent = row
		UiKit.RoundButton(button, 4)

		button.MouseButton1Click:Connect(function()
			Remotes.RequestCraft:FireServer(recipe.Id)
		end)
	end

	local pending = nil

	local function refresh(data)
		pending = data.CraftPending
	end

	Remotes.PlayerDataUpdated.OnClientEvent:Connect(refresh)

	task.spawn(function()
		while true do
			task.wait(1)
			if pending then
				local secondsLeft = math.max(0, pending.ReadyAt - os.time())
				statusLabel.Text = string.format("Crafting %s... %ds left", pending.RecipeId, secondsLeft)
			else
				statusLabel.Text = "No craft in progress."
			end
		end
	end)

	ContextActionService:BindAction("ToggleCrafting", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.C)
end

return CraftingController
