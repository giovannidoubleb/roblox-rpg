--[[
	Client entry point. Boots all client-side controllers. PerformanceController
	goes first (nothing else depends on Init having run, but it should own
	graphics settings before anything renders), then ToastController since
	LootController/NotifyController both feed into it.
]]

local PerformanceController = require(script.PerformanceController)

local ToastController = require(script.Controllers.ToastController)
local HudController = require(script.Controllers.HudController)
local CombatController = require(script.Controllers.CombatController)
local LootController = require(script.Controllers.LootController)
local NotifyController = require(script.Controllers.NotifyController)
local InventoryController = require(script.Controllers.InventoryController)
local DailyController = require(script.Controllers.DailyController)
local FeedbackController = require(script.Controllers.FeedbackController)
local DeathController = require(script.Controllers.DeathController)
local SkillController = require(script.Controllers.SkillController)
local CraftingController = require(script.Controllers.CraftingController)
local MerchantController = require(script.Controllers.MerchantController)
local ZoneController = require(script.Controllers.ZoneController)
local SeasonController = require(script.Controllers.SeasonController)
local NicknameController = require(script.Controllers.NicknameController)
local CosmeticController = require(script.Controllers.CosmeticController)
local SettingsController = require(script.Controllers.SettingsController)
local InviteController = require(script.Controllers.InviteController)
local OnboardingController = require(script.Controllers.OnboardingController)

PerformanceController.Init()

ToastController.Init()
HudController.Init()
CombatController.Init()
LootController.Init()
NotifyController.Init()
InventoryController.Init()
DailyController.Init()
FeedbackController.Init()
DeathController.Init()
SkillController.Init()
CraftingController.Init()
MerchantController.Init()
ZoneController.Init()
SeasonController.Init()
NicknameController.Init()
CosmeticController.Init()
SettingsController.Init()
InviteController.Init()
OnboardingController.Init()
