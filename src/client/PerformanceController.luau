--[[
	Client-side performance mode: auto-detects touch-only (mobile) devices
	and dials down non-gameplay-affecting cost - particle burst counts,
	camera shake magnitude, and shadow/lighting quality - since none of that
	changes what a fight actually does, only how heavy it is to render.
	SettingsController lets a player override the auto-detected default
	either way and persists the choice (see PlayerDataService.Settings).
]]

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local PerformanceController = {}

local listeners: { (boolean) -> () } = {}

-- Touch-only (no physical keyboard/mouse) is the reliable, engine-provided
-- signal for "this is a phone/tablet" - GetPropertyChangedSignal on device
-- capability isn't available, so this is read once at boot, which is when
-- it matters (a device doesn't change class mid-session).
local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled and not UserInputService.KeyboardEnabled

local lowEffects = isMobile

local function applyLighting()
	Lighting.GlobalShadows = not lowEffects
end

function PerformanceController.IsLowEffects(): boolean
	return lowEffects
end

function PerformanceController.SetLowEffects(value: boolean)
	if lowEffects == value then
		return
	end
	lowEffects = value
	applyLighting()
	for _, listener in listeners do
		task.spawn(listener, lowEffects)
	end
end

function PerformanceController.OnChanged(callback: (boolean) -> ())
	table.insert(listeners, callback)
end

-- Scales particle counts/shake magnitude: full on desktop, cut down on
-- mobile/low-effects so a busy fight doesn't tank frame rate on weaker GPUs.
function PerformanceController.GetEffectsScale(): number
	return lowEffects and 0.4 or 1
end

function PerformanceController.Init()
	applyLighting()
end

return PerformanceController
