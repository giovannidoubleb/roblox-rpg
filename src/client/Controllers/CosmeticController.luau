--[[
	Applies each player's equipped cosmetic (a color/material re-skin, see
	Config.Cosmetics) to their character. Reads the "Cosmetic" Player
	attribute, which PlayerDataService replicates server-side, so this
	works for every player's character, not just your own.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)

local CosmeticController = {}

-- Weak-keyed so entries for destroyed/respawned characters' parts are
-- reclaimed automatically instead of accumulating forever.
local originalAppearance = setmetatable({}, { __mode = "k" })

local function applyCosmetic(character: Model, cosmeticId: string)
	local def = cosmeticId ~= "" and Config.Cosmetics.Available[cosmeticId] or nil

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			if not originalAppearance[part] then
				originalAppearance[part] = { Color = part.Color, Material = part.Material }
			end

			if def then
				part.Color = def.Color
				part.Material = def.Material
			else
				local original = originalAppearance[part]
				part.Color = original.Color
				part.Material = original.Material
			end
		end
	end
end

local function watchPlayer(player: Player)
	local function onCharacterAdded(character: Model)
		local cosmeticId = player:GetAttribute("Cosmetic")
		applyCosmetic(character, typeof(cosmeticId) == "string" and cosmeticId or "")
	end

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)

	player:GetAttributeChangedSignal("Cosmetic"):Connect(function()
		if player.Character then
			onCharacterAdded(player.Character)
		end
	end)
end

function CosmeticController.Init()
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
end

return CosmeticController
