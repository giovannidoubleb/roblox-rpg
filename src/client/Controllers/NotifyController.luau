--[[
	Generic server -> client toast messages (quest complete, dungeon
	status, inventory full, purchase feedback, etc).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToastController = require(script.Parent.ToastController)

local NotifyController = {}

function NotifyController.Init()
	Remotes.Notify.OnClientEvent:Connect(function(text)
		ToastController.Show(text)
	end)
end

return NotifyController
