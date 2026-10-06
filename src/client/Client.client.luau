-- CITY GRIND: client entry point (StarterPlayerScripts.CityGrindClient).

local Players = game:GetService("Players")

local Movement = require(script:WaitForChild("Movement"))
local HUD = require(script:WaitForChild("HUD"))
local Phone = require(script:WaitForChild("Phone"))

local player = Players.LocalPlayer

Movement.start()
HUD.start()
Phone.start()

-- Wait for the server to hand over this player's save before welcoming them.
if not player:GetAttribute("DataLoaded") then
	player:GetAttributeChangedSignal("DataLoaded"):Wait()
end
HUD.push("WELCOME TO THE NEIGHBORHOOD", "Press P for your phone. Run the route by your apartment to earn cash.")
