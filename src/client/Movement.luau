-- CITY GRIND: sprint, stamina, crouch and slide (section 12).
-- PC: Shift sprint, C crouch (C while sprinting = slide).
-- Mobile: on-screen Sprint (toggle) and Crouch buttons. Controller: L3 sprint, R3 crouch.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))
local remotes = ReplicatedStorage.CityGrind:WaitForChild("Remotes")

local player = Players.LocalPlayer

local Movement = {}

local stamina = 100
local exhausted = false
local wantSprint = false
local crouching = false
local slidingUntil = 0
local humanoid: Humanoid? = nil
local lastJumpState = false

local function statValue(name: string): number
	return player:GetAttribute(name) or 1
end

function Movement.maxStamina(): number
	return Config.maxStamina(statValue("Stamina"))
end

function Movement.getStamina(): (number, number, boolean)
	return stamina, Movement.maxStamina(), exhausted
end

function Movement.isSprinting(): boolean
	return humanoid ~= nil and humanoid.WalkSpeed >= Config.SPRINT_SPEED - 0.1
end

local function setCameraOffset(y: number)
	if humanoid then
		TweenService:Create(humanoid, TweenInfo.new(0.18), { CameraOffset = Vector3.new(0, y, 0) }):Play()
	end
end

local function setCrouch(on: boolean)
	if crouching == on then
		return
	end
	crouching = on
	setCameraOffset(if on then -1.6 else 0)
end

local function trySlide(): boolean
	if not humanoid or os.clock() < slidingUntil then
		return false
	end
	if humanoid.MoveDirection.Magnitude < 0.1 or humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	if stamina < Config.SLIDE_COST then
		return false
	end
	stamina -= Config.SLIDE_COST
	slidingUntil = os.clock() + Config.SLIDE_SECONDS
	setCameraOffset(-2)
	task.delay(Config.SLIDE_SECONDS, function()
		setCameraOffset(if crouching then -1.6 else 0)
	end)
	return true
end

local function onSprint(_, state: Enum.UserInputState, input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		if state == Enum.UserInputState.Begin then
			wantSprint = not wantSprint -- toggle on mobile
		end
	elseif state == Enum.UserInputState.Begin then
		wantSprint = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		wantSprint = false
	end
	return Enum.ContextActionResult.Pass
end

local function onCrouch(_, state: Enum.UserInputState)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if Movement.isSprinting() and trySlide() then
		return Enum.ContextActionResult.Sink
	end
	setCrouch(not crouching)
	if crouching then
		wantSprint = false
	end
	return Enum.ContextActionResult.Sink
end

local function bindCharacter(character: Model)
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	crouching = false
	slidingUntil = 0
	stamina = Movement.maxStamina()
	exhausted = false
	local h = humanoid :: Humanoid
	h.WalkSpeed = Config.WALK_SPEED
	h.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping and not lastJumpState then
			stamina = math.max(0, stamina - 4)
		end
		lastJumpState = new == Enum.HumanoidStateType.Jumping
	end)
end

function Movement.start()
	ContextActionService:BindAction("CitySprint", onSprint, true, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle("CitySprint", "Sprint")
	ContextActionService:SetPosition("CitySprint", UDim2.new(1, -170, 1, -150))
	ContextActionService:BindAction("CityCrouch", onCrouch, true, Enum.KeyCode.C, Enum.KeyCode.ButtonR3)
	ContextActionService:SetTitle("CityCrouch", "Crouch")
	ContextActionService:SetPosition("CityCrouch", UDim2.new(1, -230, 1, -95))

	remotes:WaitForChild("StaminaRefill").OnClientEvent:Connect(function()
		stamina = Movement.maxStamina()
		exhausted = false
	end)

	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	player.CharacterAdded:Connect(bindCharacter)

	RunService.Heartbeat:Connect(function(dt)
		local h = humanoid
		if not h or h.Health <= 0 then
			return
		end
		local maxS = Movement.maxStamina()
		local moving = h.MoveDirection.Magnitude > 0.1
		local sliding = os.clock() < slidingUntil
		local canSprint = wantSprint and moving and not crouching and not exhausted and not UserInputService:GetFocusedTextBox()

		local speed
		if sliding then
			speed = Config.SLIDE_SPEED
		elseif canSprint then
			speed = Config.SPRINT_SPEED
			-- Better Speed stat makes sprinting cheaper (movement efficiency).
			local efficiency = 1 - (statValue("Speed") - 1) / 200
			stamina -= Config.SPRINT_DRAIN_PER_SEC * efficiency * dt
			if stamina <= 0 then
				stamina = 0
				exhausted = true
			end
		elseif crouching then
			speed = Config.CROUCH_SPEED
		else
			speed = Config.WALK_SPEED
		end

		if not canSprint and not sliding then
			local regen = Config.staminaRegen(statValue("Stamina"))
			if not moving then
				regen *= 1.5
			end
			stamina = math.min(maxS, stamina + regen * dt)
			if exhausted and stamina >= Config.MIN_SPRINT_STAMINA * 2 then
				exhausted = false
			end
		end
		stamina = math.min(stamina, maxS)
		h.WalkSpeed = speed
	end)
end

return Movement
