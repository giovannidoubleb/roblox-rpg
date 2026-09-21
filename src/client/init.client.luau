--[[
	Client entry point. Boots all client-side controllers.
]]

local HudController = require(script.Controllers.HudController)
local CombatController = require(script.Controllers.CombatController)
local LootController = require(script.Controllers.LootController)

HudController.Init()
CombatController.Init()
LootController.Init()
