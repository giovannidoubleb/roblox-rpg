--[[
	Zone travel: a free, physical shrine-to-shrine trip (marks the target
	zone discovered), plus a from-anywhere instant trip for players who own
	the Fast Travel pass or spend a Zone Skip Key - both require the target
	zone to have been physically discovered first.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local LevelLayout = require(script.Parent.LevelLayout)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local ZoneService = {}

local ZONE_SPAWN = {
	Hub = LevelLayout.PlayerSpawn,
	Wilds = LevelLayout.WildsSpawn,
}

local function teleportPlayer(player: Player, position: Vector3)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp.CFrame = CFrame.new(position)
	end
end

local function travelTo(player: Player, zoneName: string)
	local position = ZONE_SPAWN[zoneName]
	if not position then
		return
	end

	teleportPlayer(player, position)
	PlayerDataService.DiscoverZone(player, zoneName)
end

function ZoneService.Init()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if prompt.Name == "TravelToWildsPrompt" then
			travelTo(player, "Wilds")
		elseif prompt.Name == "TravelToHubPrompt" then
			travelTo(player, "Hub")
		end
	end)

	Remotes.RequestZoneTravel.OnServerEvent:Connect(function(player, zoneName)
		if typeof(zoneName) ~= "string" or not Config.Zones[zoneName] then
			return
		end

		local data = PlayerDataService.Get(player)
		if not data or not data.DiscoveredZones[zoneName] then
			Remotes.Notify:FireClient(player, "Find that zone on foot first.")
			return
		end

		if PlayerDataService.HasPass(player, "FastTravel") then
			travelTo(player, zoneName)
			return
		end

		if (data.Consumables.ZoneSkipKey or 0) > 0 then
			data.Consumables.ZoneSkipKey -= 1
			PlayerDataService.PushUpdate(player)
			travelTo(player, zoneName)
			return
		end

		Remotes.Notify:FireClient(player, "Fast travel needs the Fast Travel pass or a Zone Skip Key.")
	end)
end

return ZoneService
