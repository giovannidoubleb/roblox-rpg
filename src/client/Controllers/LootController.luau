--[[
	Shows a toast when the server awards loot. Rarity colors match the
	tiers from the design doc (Common white -> Legendary orange). A rare
	drop gets a bigger sparkle burst and a touch of screen shake so a
	Legendary actually feels like a moment, not just a different toast color.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToastController = require(script.Parent.ToastController)
local Sfx = require(script.Parent.Parent.Sfx)
local Shake = require(script.Parent.Parent.Shake)
local Particles = require(script.Parent.Parent.Particles)

local LootController = {}

local player = Players.LocalPlayer

local RARITY_COLOR = {
	Common = Color3.fromRGB(255, 255, 255),
	Uncommon = Color3.fromRGB(70, 200, 90),
	Rare = Color3.fromRGB(70, 140, 230),
	Epic = Color3.fromRGB(170, 80, 230),
	Legendary = Color3.fromRGB(240, 150, 40),
}

local RARITY_BURST = {
	Common = 0,
	Uncommon = 6,
	Rare = 10,
	Epic = 16,
	Legendary = 24,
}

function LootController.Init()
	Remotes.LootReceived.OnClientEvent:Connect(function(loot)
		local color = RARITY_COLOR[loot.Rarity] or Color3.new(1, 1, 1)
		ToastController.Show(string.format("+ %s (%s)", loot.Name, loot.Rarity), color)
		Sfx.Play(Sfx.Ids.Loot, loot.Rarity == "Legendary" and 0.7 or 0.4)

		local burst = RARITY_BURST[loot.Rarity] or 0
		if burst > 0 then
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				Particles.Burst(root.Position, color, burst, 8)
			end
		end
		if loot.Rarity == "Epic" or loot.Rarity == "Legendary" then
			Shake.Trigger(loot.Rarity == "Legendary" and 0.5 or 0.25)
		end
	end)
end

return LootController
