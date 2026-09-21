--[[
	Sends attack requests to the server. Purely an input -> remote bridge;
	the server decides whether the attack actually lands (see
	CombatService). Bound through ContextActionService so it works with
	mouse, touch, and gamepad without extra platform branching.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CombatController = {}

local ACTION_NAME = "RpgAttack"

local function onAttackAction(_actionName, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin then
		Remotes.RequestAttack:FireServer()
	end
	return Enum.ContextActionResult.Pass
end

function CombatController.Init()
	ContextActionService:BindAction(
		ACTION_NAME,
		onAttackAction,
		true,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch,
		Enum.KeyCode.ButtonR2
	)
	ContextActionService:SetTitle(ACTION_NAME, "Attack")
end

return CombatController
