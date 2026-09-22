--[[
	Purely cosmetic follower pets - no combat stats, just a reason to spend
	gems at the merchant and a visible perk for the Companion Slot
	Expansion pass. A slow loop keeps each player's spawned companion
	models in sync with their profile's Companions.Active list and trails
	them a couple of studs behind the player.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CompanionService = {}

local TICK_SECONDS = 0.2
local FOLLOW_LERP = 0.15

-- [Player]: { [companionId]: Model }
local activeModels: { [Player]: { [string]: Model } } = {}

local function buildCompanionModel(companionId: string): Model?
	local def = Config.Companions.Available[companionId]
	if not def then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = companionId

	local part = Instance.new("Part")
	part.Name = "Root"
	part.Shape = def.Shape
	part.Size = Vector3.new(1.4, 1.4, 1.4)
	part.Color = def.Color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.Parent = model

	model.PrimaryPart = part
	model.Parent = Workspace

	return model
end

local function syncPlayer(player: Player)
	local data = PlayerDataService.Get(player)
	local models = activeModels[player]
	if not models then
		models = {}
		activeModels[player] = models
	end

	if not data then
		for companionId, model in models do
			model:Destroy()
			models[companionId] = nil
		end
		return
	end

	local desired = {}
	for _, companionId in data.Companions.Active do
		desired[companionId] = true
	end

	for companionId, model in models do
		if not desired[companionId] then
			model:Destroy()
			models[companionId] = nil
		end
	end

	for companionId in desired do
		if not models[companionId] then
			models[companionId] = buildCompanionModel(companionId)
		end
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local slot = 0
	for _, companionId in data.Companions.Active do
		local model = models[companionId]
		if model and model.PrimaryPart then
			slot += 1
			local offset = hrp.CFrame:VectorToWorldSpace(Vector3.new((slot % 2 == 0) and 2.5 or -2.5, 1.5, 3 + slot))
			local targetPosition = hrp.Position + offset
			local current = model.PrimaryPart.Position
			model:PivotTo(CFrame.new(current:Lerp(targetPosition, FOLLOW_LERP)))
		end
	end
end

local function onPlayerRemoving(player: Player)
	local models = activeModels[player]
	if models then
		for _, model in models do
			model:Destroy()
		end
		activeModels[player] = nil
	end
end

function CompanionService.Init()
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)
			for _, player in Players:GetPlayers() do
				syncPlayer(player)
			end
		end
	end)
end

return CompanionService
