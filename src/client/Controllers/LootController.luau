--[[
	Shows a toast when the server awards loot. Rarity colors match the
	tiers from the design doc (Common white -> Legendary orange).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToastController = require(script.Parent.ToastController)
local Sfx = require(script.Parent.Parent.Sfx)

local LootController = {}

local RARITY_COLOR = {
	Common = Color3.fromRGB(255, 255, 255),
	Uncommon = Color3.fromRGB(70, 200, 90),
	Rare = Color3.fromRGB(70, 140, 230),
	Epic = Color3.fromRGB(170, 80, 230),
	Legendary = Color3.fromRGB(240, 150, 40),
}

function LootController.Init()
	Remotes.LootReceived.OnClientEvent:Connect(function(loot)
		ToastController.Show(string.format("+ %s (%s)", loot.Name, loot.Rarity), RARITY_COLOR[loot.Rarity])
		Sfx.Play(Sfx.Ids.Loot, 0.4)
	end)
end

return LootController
