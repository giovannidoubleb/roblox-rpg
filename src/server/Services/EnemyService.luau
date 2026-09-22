--[[
	Spawns and drives simple enemy NPCs. Enemies are built from parts at
	runtime rather than Studio-authored models, so the scaffold works
	without any external assets. AI is a minimal chase-and-melee (or
	chase-and-lob, for ranged kinds) loop, not pathfinding.

	Config.EnemyKinds gives each enemy a look and picks a Config.EnemyTiers
	power baseline (Health/Damage/XP/etc.) for it; EnemyService.Spawn takes
	a kind name (e.g. "Slime"), not a tier name directly, but still reports
	deaths with the base tier name so XP/loot/quest matching (which only
	knows about Trash/Elite/Boss) is unaffected by how many kinds exist.

	Field enemies (EnemyService.Init) spawn from LevelLayout.FieldSpawns/
	WildsFieldSpawns and respawn forever. DungeonService spawns additional,
	non-respawning waves through EnemyService.Spawn for the key-gated
	dungeon run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local LevelLayout = require(script.Parent.LevelLayout)

local EnemyService = {}

-- Kept well under the hub's ~40-stud half-size so a fresh spawn doesn't get
-- simultaneously aggroed by everything in the room (that was reading as "I
-- keep dying" - multiple trash converging on a level 1 character with no
-- regen has nothing to do with a bug, it's an aggro-range balance problem).
local AGGRO_RANGE = 20
local AI_TICK_SECONDS = 0.5
local BOLT_TRAVEL_SECONDS = 0.2

local onEnemyDied: (enemy: Model, tierName: string, killer: Player?) -> () = function() end

function EnemyService.SetOnEnemyDied(callback)
	onEnemyDied = callback
end

local function fireBolt(fromPosition: Vector3, toPosition: Vector3, color: Color3)
	local bolt = Instance.new("Part")
	bolt.Name = "Bolt"
	bolt.Size = Vector3.new(0.6, 0.6, 0.6)
	bolt.Shape = Enum.PartType.Ball
	bolt.Color = color
	bolt.Material = Enum.Material.Neon
	bolt.Anchored = true
	bolt.CanCollide = false
	bolt.CFrame = CFrame.new(fromPosition)
	bolt.Parent = Workspace

	local tween = TweenService:Create(bolt, TweenInfo.new(BOLT_TRAVEL_SECONDS, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(toPosition),
	})
	tween.Completed:Connect(function()
		bolt:Destroy()
	end)
	tween:Play()

	task.delay(1, function()
		if bolt.Parent then
			bolt:Destroy()
		end
	end)
end

local function buildEnemy(kindName: string): Model
	local kindDef = Config.EnemyKinds[kindName]
	local tier = Config.EnemyTiers[kindDef.Tier]

	local model = Instance.new("Model")
	model.Name = kindName

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Shape = kindDef.Shape
	root.Size = tier.IsBoss and Vector3.new(5, 7, 5) or Vector3.new(2.2, 3, 2.2)
	root.Color = kindDef.Color
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = tier.Health
	humanoid.Health = tier.Health
	humanoid.WalkSpeed = tier.IsBoss and 10 or 14
	humanoid.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("Tier", kindDef.Tier)
	model:SetAttribute("Kind", kindName)

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

local function runAi(model: Model, kindName: string)
	local kindDef = Config.EnemyKinds[kindName]
	local tier = Config.EnemyTiers[kindDef.Tier]
	local attackRange = kindDef.AttackRange or tier.AttackRange

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

			if distance <= attackRange then
				humanoid:MoveTo(root.Position)
				local now = os.clock()
				if now - lastAttackAt >= tier.AttackCooldown then
					lastAttackAt = now
					local targetHumanoid = target.Character:FindFirstChildOfClass("Humanoid")
					if targetHumanoid then
						if kindDef.Ranged then
							fireBolt(root.Position, targetHrp.Position, kindDef.Color)
						end
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
function EnemyService.Spawn(kindName: string, position: Vector3, options: { Respawn: boolean?, Tags: { [string]: any }? }?)
	options = options or {}
	local respawn = options.Respawn ~= false

	local model = buildEnemy(kindName)
	if options.Tags then
		for attributeName, value in options.Tags do
			model:SetAttribute(attributeName, value)
		end
	end

	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local tierName = Config.EnemyKinds[kindName].Tier
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
				EnemyService.Spawn(kindName, position, options)
			end)
		end
	end)

	task.spawn(runAi, model, kindName)

	return model
end

function EnemyService.Init()
	for _, spawnPoint in LevelLayout.FieldSpawns do
		EnemyService.Spawn(spawnPoint.Kind, spawnPoint.Position)
	end
	for _, spawnPoint in LevelLayout.WildsFieldSpawns do
		EnemyService.Spawn(spawnPoint.Kind, spawnPoint.Position)
	end

	-- A respawning field boss out in the Wilds - a reason to make the trip
	-- beyond just the trash/elite grind, on top of the daily dungeon.
	EnemyService.Spawn(LevelLayout.WildsBossKind, LevelLayout.WildsBossPosition)
end

return EnemyService
