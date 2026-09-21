--[[
	Server entry point. Boots all server-side services.
]]

local PlayerDataService = require(script.Services.PlayerDataService)

PlayerDataService.Init()
