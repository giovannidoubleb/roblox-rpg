--[[
	Two code-built, stationary NPCs near spawn so the hub isn't just mobs on
	a lawn: a quest giver (opens the daily panel) and a merchant (opens the
	shop panel for companions/cosmetics). No external assets - a colored
	block body, ball head, and a floating name tag.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LevelLayout = require(script.Parent.LevelLayout)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local NpcService = {}

local function buildNpc(name: string, position: Vector3, bodyColor: Color3, promptName: string, actionText: string, objectText: string): Model
	local model = Instance.new("Model")
	model.Name = name

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2, 3, 1)
	body.Color = bodyColor
	body.Anchored = true
	body.CanCollide = true
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Position = position
	body.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.4, 1.4, 1.4)
	head.Color = Color3.fromRGB(230, 200, 170)
	head.Anchored = true
	head.CanCollide = false
	head.Position = position + Vector3.new(0, 2.2, 0)
	head.Parent = model

	model.PrimaryPart = body

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.new(0, 140, 0, 32)
	billboard.StudsOffset = Vector3.new(0, 3.2, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = name
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = promptName
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 10
	prompt.Parent = body

	model.Parent = Workspace
	return model
end

function NpcService.Init()
	buildNpc("Quest Giver", LevelLayout.QuestGiverPosition, Color3.fromRGB(90, 140, 200), "OpenQuestGiverPrompt", "Talk", "Daily Quests")
	buildNpc("Merchant", LevelLayout.MerchantPosition, Color3.fromRGB(180, 140, 60), "OpenMerchantPrompt", "Shop", "Merchant")

	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name == "OpenQuestGiverPrompt" then
			Remotes.OpenDailyPanel:FireClient(player)
		elseif prompt.Name == "OpenMerchantPrompt" then
			Remotes.OpenMerchantPanel:FireClient(player)
		end
	end)
end

return NpcService
