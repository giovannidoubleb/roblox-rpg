--[[
	Spawns and drives simple enemy NPCs (trash/elite/boss tiers). Enemies
	are built from parts at runtime rather than Studio-authored models, so
	the scaffold works without any external assets. AI is a minimal
	chase-and-melee loop, not pathfinding.

	Real level layout (spawn points, room geometry) is a future pass; the
	spawn list below is placeholder positions for the loop to be testable.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Modules.Config)

local EnemyService = {}

local AGGRO_RANGE = 40
local AI_TICK_SECONDS = 0.5

local TIER_COLOR = {
	Trash = Color3.fromRGB(150, 150, 150),
	Elite = Color3.fromRGB(90, 90, 200),
	Boss = Color3.fromRGB(180, 40, 40),
}

local onEnemyDied: (enemy: Model, tierName: string, killer: Player?) -> () = function() end

function EnemyService.SetOnEnemyDied(callback)
	onEnemyDied = callback
end

local function buildEnemy(tierName: string): Model
	local tier = Config.EnemyTiers[tierName]

	local model = Instance.new("Model")
	model.Name = tierName

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = tier.IsBoss and Vector3.new(4, 6, 4) or Vector3.new(2, 3, 2)
	root.Color = TIER_COLOR[tierName]
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = tier.Health
	humanoid.Health = tier.Health
	humanoid.WalkSpeed = tier.IsBoss and 10 or 14
	humanoid.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("Tier", tierName)

	return model
end

local function nearestPlayerCharacter(fromPosition: Vector3)
	local closest, closestDistance = nil, AGGRO_RANGE

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if hrp and humanoid and humanoid.Health > 0 then
			local distance = (hrp.Position - fromPosition).Magnitude
			if distance < closestDistance then
				closest, closestDistance = player, distance
			end
		end
	end

	return closest, closestDistance
end

local function runAi(model: Model, tierName: string)
	local tier = Config.EnemyTiers[tierName]
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model.PrimaryPart :: BasePart

	local lastAttackAt = 0

	while model.Parent and humanoid.Health > 0 do
		task.wait(AI_TICK_SECONDS)
		if not model.Parent then
			break
		end

		local target, distance = nearestPlayerCharacter(root.Position)
		if target then
			local targetHrp = target.Character.HumanoidRootPart :: BasePart

			if distance <= tier.AttackRange then
				humanoid:MoveTo(root.Position)
				local now = os.clock()
				if now - lastAttackAt >= tier.AttackCooldown then
					lastAttackAt = now
					local targetHumanoid = target.Character:FindFirstChildOfClass("Humanoid")
					if targetHumanoid then
						targetHumanoid:TakeDamage(tier.Damage)
					end
				end
			else
				humanoid:MoveTo(targetHrp.Position)
			end
		end
	end
end

local function spawnAt(tierName: string, position: Vector3)
	local model = buildEnemy(tierName)
	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local killer: Player? = nil

	-- Track the last player to damage this enemy so kills can be
	-- attributed. Server-authoritative damage always goes through
	-- CombatService, which sets this attribute right before TakeDamage.
	model:GetAttributeChangedSignal("LastDamagedBy"):Connect(function()
		local userId = model:GetAttribute("LastDamagedBy")
		killer = userId and Players:GetPlayerByUserId(userId) or nil
	end)

	humanoid.Died:Connect(function()
		onEnemyDied(model, tierName, killer)
		task.delay(0.5, function()
			model:Destroy()
		end)
		task.delay(Config.EnemyTiers[tierName].RespawnSeconds, function()
			spawnAt(tierName, position)
		end)
	end)

	task.spawn(runAi, model, tierName)

	return model
end

-- Placeholder spawn layout until real level geometry exists.
local SPAWN_POINTS = {
	{ Tier = "Trash", Position = Vector3.new(10, 5, 0) },
	{ Tier = "Trash", Position = Vector3.new(-10, 5, 0) },
	{ Tier = "Trash", Position = Vector3.new(0, 5, 15) },
	{ Tier = "Elite", Position = Vector3.new(20, 5, 20) },
	{ Tier = "Boss", Position = Vector3.new(0, 5, 40) },
}

function EnemyService.Init()
	for _, spawnPoint in SPAWN_POINTS do
		spawnAt(spawnPoint.Tier, spawnPoint.Position)
	end
end

return EnemyService
