--[[
	Listens for player data updates from the server and will drive the HUD.
	No UI wired up yet - this just confirms the client/server pipe works.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local HudController = {}

local function onPlayerDataUpdated(data)
	print(string.format("[HudController] level %d, hp %d/%d", data.Level, data.Health, data.MaxHealth))
end

function HudController.Init()
	Remotes.PlayerDataUpdated.OnClientEvent:Connect(onPlayerDataUpdated)
end

return HudController
