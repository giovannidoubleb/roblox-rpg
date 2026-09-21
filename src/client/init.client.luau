--[[
	Client entry point. Boots all client-side controllers. ToastController
	goes first since LootController/NotifyController both feed into it.
]]

local ToastController = require(script.Controllers.ToastController)
local HudController = require(script.Controllers.HudController)
local CombatController = require(script.Controllers.CombatController)
local LootController = require(script.Controllers.LootController)
local NotifyController = require(script.Controllers.NotifyController)
local InventoryController = require(script.Controllers.InventoryController)
local DailyController = require(script.Controllers.DailyController)

ToastController.Init()
HudController.Init()
CombatController.Init()
LootController.Init()
NotifyController.Init()
InventoryController.Init()
DailyController.Init()
