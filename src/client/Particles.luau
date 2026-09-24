--[[
	Tiny burst-particle helper: spawns a short-lived, anchored, invisible
	part with a ParticleEmitter, fires a fixed count, then cleans itself up.
	No external art - ParticleEmitter's default round texture is used with
	color/size, which reads fine for hit sparks and pickup sparkle.
]]

local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local PerformanceController = require(script.Parent.PerformanceController)

local Particles = {}

function Particles.Burst(worldPosition: Vector3, color: Color3, count: number, spread: number?)
	count = math.floor(count * PerformanceController.GetEffectsScale())
	if count <= 0 then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = "ParticleAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CFrame = CFrame.new(worldPosition)
	anchor.Parent = Workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.25, 0.5)
	emitter.Speed = NumberRange.new(spread or 6, (spread or 6) * 1.6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = anchor

	emitter:Emit(count)
	Debris:AddItem(anchor, 1)
end

return Particles
