--[[
	Thin remote-to-PlayerDataService wiring for the smaller progression
	systems: skill point allocation/respec, nicknames, cosmetics,
	companions, and season pass tier claims. Each handler just validates
	the wire shape and hands off - the actual rules (costs, ownership,
	caps) live in PlayerDataService next to the profile they mutate.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local ProgressionService = {}

function ProgressionService.Init()
	Remotes.RequestAllocateSkill.OnServerEvent:Connect(function(player, statName)
		if typeof(statName) == "string" then
			PlayerDataService.AllocateSkillPoint(player, statName)
		end
	end)

	Remotes.RequestRespecSkills.OnServerEvent:Connect(function(player)
		PlayerDataService.RespecSkills(player)
	end)

	Remotes.RequestSetNickname.OnServerEvent:Connect(function(player, rawName)
		if typeof(rawName) == "string" then
			PlayerDataService.SetNickname(player, rawName)
		end
	end)

	Remotes.RequestPurchaseCosmetic.OnServerEvent:Connect(function(player, cosmeticId)
		if typeof(cosmeticId) == "string" then
			PlayerDataService.PurchaseCosmeticWithGems(player, cosmeticId)
		end
	end)

	Remotes.RequestEquipCosmetic.OnServerEvent:Connect(function(player, cosmeticId)
		if typeof(cosmeticId) == "string" then
			PlayerDataService.EquipCosmetic(player, cosmeticId)
		end
	end)

	Remotes.RequestPurchaseCompanion.OnServerEvent:Connect(function(player, companionId)
		if typeof(companionId) == "string" then
			PlayerDataService.PurchaseCompanion(player, companionId)
		end
	end)

	Remotes.RequestSetActiveCompanions.OnServerEvent:Connect(function(player, companionIds)
		if typeof(companionIds) == "table" then
			PlayerDataService.SetActiveCompanions(player, companionIds)
		end
	end)

	Remotes.RequestClaimSeasonTier.OnServerEvent:Connect(function(player, tierIndex)
		if typeof(tierIndex) == "number" then
			PlayerDataService.ClaimSeasonTier(player, tierIndex)
		end
	end)
end

return ProgressionService
