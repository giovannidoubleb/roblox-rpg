--[[
	Additive camera shake: any number of callers can Trigger a shake and they
	stack (a hit landing during a boss Slam's shake feels bigger, not reset).
	Bound at Camera priority + 1 so it applies after the default camera
	script has already positioned the camera each frame, instead of racing
	it. Only bound while a shake is actually active, so it costs nothing the
	rest of the time.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PerformanceController = require(script.Parent.PerformanceController)

local Shake = {}

local BINDING_NAME = "RpgCameraShake"

local magnitude = 0
local bound = false

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera or magnitude <= 0.01 then
		magnitude = 0
		RunService:UnbindFromRenderStep(BINDING_NAME)
		bound = false
		return
	end

	local offset = Vector3.new(
		(math.random() - 0.5) * magnitude,
		(math.random() - 0.5) * magnitude,
		0
	)
	camera.CFrame = camera.CFrame * CFrame.new(offset)
	magnitude = math.max(0, magnitude - magnitude * dt * 6)
end

-- strength: roughly 0.1 (small hit) to 1.2 (boss slam / level up).
function Shake.Trigger(strength: number)
	magnitude = math.min(2, magnitude + strength * PerformanceController.GetEffectsScale())
	if not bound then
		bound = true
		RunService:BindToRenderStep(BINDING_NAME, Enum.RenderPriority.Camera.Value + 1, step)
	end
end

return Shake
