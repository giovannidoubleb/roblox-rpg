--[[
	Sends attack/skill/ultimate requests to the server. Purely an input ->
	remote bridge; the server decides whether anything actually lands (see
	CombatService). Bound through ContextActionService so it works with
	mouse, touch, and gamepad without extra platform branching - each
	action also gets an auto-generated mobile button.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CombatController = {}

local function bindFire(actionName: string, title: string, remoteFire: () -> (), ...: Enum.KeyCode | Enum.UserInputType)
	ContextActionService:BindAction(actionName, function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			remoteFire()
		end
		return Enum.ContextActionResult.Pass
	end, true, ...)
	ContextActionService:SetTitle(actionName, title)
end

function CombatController.Init()
	bindFire("RpgAttack", "Attack", function()
		Remotes.RequestAttack:FireServer()
	end, Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch, Enum.KeyCode.ButtonR2)

	bindFire("RpgCleave", "Cleave", function()
		Remotes.RequestSkill:FireServer("Cleave")
	end, Enum.KeyCode.One, Enum.KeyCode.ButtonX)

	bindFire("RpgPowerStrike", "Power Strike", function()
		Remotes.RequestSkill:FireServer("PowerStrike")
	end, Enum.KeyCode.Two, Enum.KeyCode.ButtonY)

	bindFire("RpgUltimate", "Ultimate", function()
		Remotes.RequestUltimate:FireServer()
	end, Enum.KeyCode.R, Enum.KeyCode.ButtonB)
end

return CombatController
