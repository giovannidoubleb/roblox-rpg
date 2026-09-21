--[[
	Spawns and drives simple enemy NPCs (trash/elite/boss tiers). Enemies
	are built from parts at runtime rather than Studio-authored models, so
	the scaffold works without any external assets. AI is a minimal
	chase-and-melee loop, not pathfinding.

	Field enemies (EnemyService.Init) spawn from LevelLayout.FieldSpawns and
	respawn forever. DungeonService spawns additional, non-respawning waves
	through EnemyService.Spawn for the key-gated dungeon run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local LevelLayout = require(script.Parent.LevelLayout)

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

-- options.Respawn (default true): whether a fresh copy auto-spawns after
-- this one dies, at the same position. Field enemies respawn forever;
-- dungeon-wave enemies (spawned by DungeonService) pass Respawn = false.
-- options.Tags: extra attributes to set on the model, e.g. dungeon run
-- ownership, so other services can identify/filter these enemies.
function EnemyService.Spawn(tierName: string, position: Vector3, options: { Respawn: boolean?, Tags: { [string]: any }? }?)
	options = options or {}
	local respawn = options.Respawn ~= false

	local model = buildEnemy(tierName)
	if options.Tags then
		for attributeName, value in options.Tags do
			model:SetAttribute(attributeName, value)
		end
	end

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
		if respawn then
			task.delay(Config.EnemyTiers[tierName].RespawnSeconds, function()
				EnemyService.Spawn(tierName, position, options)
			end)
		end
	end)

	task.spawn(runAi, model, tierName)

	return model
end

function EnemyService.Init()
	for _, spawnPoint in LevelLayout.FieldSpawns do
		EnemyService.Spawn(spawnPoint.Tier, spawnPoint.Position)
	end
end

return EnemyService
