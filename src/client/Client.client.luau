-- CITY GRIND: client entry point (StarterPlayerScripts.CityGrindClient).

local Players = game:GetService("Players")

local Movement = require(script:WaitForChild("Movement"))
local HUD = require(script:WaitForChild("HUD"))
local Phone = require(script:WaitForChild("Phone"))
local Basketball = require(script:WaitForChild("Basketball"))

local player = Players.LocalPlayer

Movement.start()
HUD.start()

-- Phase 3 life systems. They start before the phone so their apps
-- (Phone.addApp) land on the home screen.
for _, name in { "Jobs", "Gym", "Vehicles", "Apartments", "Shops", "Social", "Messages", "Party", "Crews", "Emotes", "Media", "CityGram", "CityTok", "Calls", "Bank", "Events", "Music", "Quests", "Story", "World" } do
	local module = script:FindFirstChild(name)
	if module then
		local ok, err = pcall(function()
			require(module).start()
		end)
		if not ok then
			warn("[CityGrind] " .. name .. " failed to start:", err)
		end
	end
end

Phone.start()
Basketball.start()

-- Wait for the server to hand over this player's save before welcoming them.
if not player:GetAttribute("DataLoaded") then
	player:GetAttributeChangedSignal("DataLoaded"):Wait()
end
HUD.push("WELCOME TO THE NEIGHBORHOOD", "Press P for your phone. Run the route by your apartment to earn cash.")
