--[[
	Spawns and drives enemy NPCs. Enemies are built from parts at runtime
	rather than Studio-authored models, so the scaffold works without any
	external assets. AI is chase-into-range, not pathfinding, but attacks
	are telegraphed rather than an instant on-cooldown tick: the enemy
	flashes for TelegraphSeconds before a hit is actually applied, and the
	hit is re-checked against range at the end of the flash, so stepping
	away during the telegraph is a real way to avoid damage. Kiter kinds
	(Warlock) back off to hold range instead of standing and trading hits,
	and every boss has a second, harder-hitting telegraphed radius Slam on
	its own cooldown.

	Config.EnemyKinds gives each enemy a look/behavior and picks a
	Config.EnemyTiers power baseline (Health/Damage/XP/etc.) for it;
	EnemyService.Spawn takes a kind name (e.g. "Slime"), not a tier name
	directly, but still reports deaths with the base tier name so XP/loot/
	quest matching (which only knows about Trash/Elite/Boss) is unaffected
	by how many kinds or champion multipliers exist.

	Field enemies (EnemyService.Init) spawn from LevelLayout.FieldSpawns/
	WildsFieldSpawns and respawn forever. DungeonService spawns additional,
	non-respawning waves through EnemyService.Spawn for the key-gated
	dungeon run, including its per-wave Champion enemy (options.Champion).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local LevelLayout = require(script.Parent.LevelLayout)
local PlayerDataService = require(script.Parent.PlayerDataService)

local EnemyService = {}

-- Kept well under the hub's ~40-stud half-size so a fresh spawn doesn't get
-- simultaneously aggroed by everything in the room (that was reading as "I
-- keep dying" - multiple trash converging on a level 1 character with no
-- regen has nothing to do with a bug, it's an aggro-range balance problem).
local AGGRO_RANGE = 20
local AI_TICK_SECONDS = 0.5
-- LOD: an enemy nobody is anywhere near (e.g. Hub trash while everyone is in
-- the Wilds or the dungeon instance) has nothing useful to compute every
-- 0.5s - it can't aggro, attack, or move toward anyone. Falling back to a
-- slow idle tick for those keeps the always-on field spawns across two zones
-- from burning CPU on players that aren't there.
local IDLE_CHECK_RADIUS = 100
local IDLE_TICK_SECONDS = 2.5
local BOLT_TRAVEL_SECONDS = 0.2
local TELEGRAPH_COLOR = Color3.fromRGB(255, 235, 90)
local SLAM_TELEGRAPH_COLOR = Color3.fromRGB(255, 80, 80)

local onEnemyDied: (enemy: Model, tierName: string, killer: Player?) -> () = function() end

function EnemyService.SetOnEnemyDied(callback)
	onEnemyDied = callback
end

-- Live registry of currently-spawned enemy models, maintained incrementally
-- on spawn/death. CombatService used to rebuild this list by scanning every
-- top-level Workspace child (bolts, telegraph rings, damage-number anchors,
-- other enemies) on *every single attack request from every player* - the
-- main source of avoidable server lag once more than a handful of enemies
-- and players were in play. Reading from this table instead is O(active
-- enemies) instead of O(everything ever parented to Workspace).
local activeEnemies: { [Model]: boolean } = {}

function EnemyService.GetActiveEnemies(): { Model }
	local list = {}
	for enemy in activeEnemies do
		list[#list + 1] = enemy
	end
	return list
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

-- options.Champion (dungeon wave modifier): scales Health/Damage up via
-- Config.Dungeon.Champion and makes the model visibly bigger/gilded so
-- players can tell at a glance this one hits differently and drops bonus
-- loot. The damage multiplier is stored as a model attribute since the AI
-- loop below reads tier.Damage directly and needs to scale it per-instance.
local function buildEnemy(kindName: string, champion: boolean?): Model
	local kindDef = Config.EnemyKinds[kindName]
	local tier = Config.EnemyTiers[kindDef.Tier]

	local healthMultiplier = 1
	local damageMultiplier = 1
	if champion then
		healthMultiplier = Config.Dungeon.Champion.HealthMultiplier
		damageMultiplier = Config.Dungeon.Champion.DamageMultiplier
	end

	local model = Instance.new("Model")
	model.Name = champion and (kindName .. " Champion") or kindName

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Shape = kindDef.Shape
	local baseSize = tier.IsBoss and Vector3.new(5, 7, 5) or Vector3.new(2.2, 3, 2.2)
	root.Size = champion and baseSize * 1.3 or baseSize
	root.Color = champion and kindDef.Color:Lerp(Color3.fromRGB(255, 215, 90), 0.5) or kindDef.Color
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = tier.Health * healthMultiplier
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = tier.IsBoss and 10 or 14
	humanoid.Parent = model

	model.PrimaryPart = root
	model:SetAttribute("Tier", kindDef.Tier)
	model:SetAttribute("Kind", kindName)
	model:SetAttribute("DamageMultiplier", damageMultiplier)
	if champion then
		model:SetAttribute("Champion", true)
	end

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

local function anyPlayerWithin(fromPosition: Vector3, radius: number): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - fromPosition).Magnitude <= radius then
			return true
		end
	end
	return false
end

local function livingHumanoid(character: Model?): Humanoid?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function runAi(model: Model, kindName: string)
	local kindDef = Config.EnemyKinds[kindName]
	local tier = Config.EnemyTiers[kindDef.Tier]
	local attackRange = kindDef.AttackRange or tier.AttackRange
	local isKiter = kindDef.Behavior == "Kiter"

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model.PrimaryPart :: BasePart

	local lastAttackAt = 0
	local lastSlamAt = 0
	local busy = false
	-- Hysteresis for Kiter kinds: once fleeing starts, keep fleeing until the
	-- player is comfortably past KiteRange rather than flipping every tick at
	-- the exact boundary (which reads as vibrating in place instead of a
	-- clean retreat-then-fight rhythm).
	local kiting = false
	local KITE_RELEASE_BUFFER = 3

	-- Flashes TELEGRAPH_COLOR for the tier's wind-up, then re-checks the
	-- target is still in range/alive before the hit actually lands - this
	-- is what makes the telegraph a real dodge window instead of decoration.
	local function performAttack(target: Player)
		busy = true
		local originalColor = root.Color
		root.Color = TELEGRAPH_COLOR
		task.wait(tier.TelegraphSeconds)
		if root.Parent then
			root.Color = originalColor
		end

		if model.Parent and humanoid.Health > 0 and target.Character then
			local targetHumanoid = livingHumanoid(target.Character)
			local targetHrp = target.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if targetHumanoid and targetHrp then
				local distance = (targetHrp.Position - root.Position).Magnitude
				if distance <= attackRange * 1.15 then
					local damage = tier.Damage * (model:GetAttribute("DamageMultiplier") or 1)
					if kindDef.Ranged then
						fireBolt(root.Position, targetHrp.Position, kindDef.Color)
					end
					PlayerDataService.DamagePlayer(target, damage)
				end
			end
		end
		busy = false
	end

	-- Boss-only: a slower, harder-hitting radius attack telegraphed with a
	-- growing warning ring on the floor, on its own cooldown separate from
	-- the basic attack - gives every boss fight a beat where standing still
	-- is the wrong answer, not just a bigger health bar.
	local function performSlam()
		busy = true
		local originalColor = root.Color
		root.Color = SLAM_TELEGRAPH_COLOR

		local ring = Instance.new("Part")
		ring.Name = "SlamTelegraph"
		ring.Anchored = true
		ring.CanCollide = false
		ring.Shape = Enum.PartType.Cylinder
		ring.Material = Enum.Material.Neon
		ring.Color = SLAM_TELEGRAPH_COLOR
		ring.Transparency = 0.7
		ring.Size = Vector3.new(0.2, tier.SlamRadius * 2, tier.SlamRadius * 2)
		ring.Orientation = Vector3.new(0, 0, 90)
		ring.CFrame = CFrame.new(root.Position - Vector3.new(0, root.Size.Y / 2 - 0.15, 0))
		ring.Parent = Workspace

		local tween = TweenService:Create(ring, TweenInfo.new(tier.SlamTelegraphSeconds, Enum.EasingStyle.Linear), {
			Transparency = 0.25,
		})
		tween:Play()

		task.wait(tier.SlamTelegraphSeconds)
		ring:Destroy()
		if root.Parent then
			root.Color = originalColor
		end

		if model.Parent and humanoid.Health > 0 then
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local targetHumanoid = livingHumanoid(character)
				local targetHrp = targetHumanoid and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if targetHumanoid and targetHrp then
					if (targetHrp.Position - root.Position).Magnitude <= tier.SlamRadius then
						PlayerDataService.DamagePlayer(player, tier.SlamDamage)
					end
				end
			end
		end
		busy = false
	end

	while model.Parent and humanoid.Health > 0 do
		if not anyPlayerWithin(root.Position, IDLE_CHECK_RADIUS) then
			task.wait(IDLE_TICK_SECONDS)
			continue
		end

		task.wait(AI_TICK_SECONDS)
		if not model.Parent then
			break
		end

		local target, distance = nearestPlayerCharacter(root.Position)
		if target then
			local targetHrp = target.Character.HumanoidRootPart :: BasePart
			local now = os.clock()

			if isKiter then
				if distance < kindDef.KiteRange then
					kiting = true
				elseif distance > kindDef.KiteRange + KITE_RELEASE_BUFFER then
					kiting = false
				end
			end

			if
				tier.IsBoss
				and not busy
				and now - lastSlamAt >= tier.SlamCooldown
				and distance <= tier.SlamRadius * 1.4
			then
				lastSlamAt = now
				humanoid:MoveTo(root.Position)
				task.spawn(performSlam)
			elseif isKiter and kiting then
				local away = (root.Position - targetHrp.Position)
				local fleeDirection = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
				humanoid:MoveTo(root.Position + fleeDirection * (kindDef.KiteRange - distance + 4))
			elseif distance <= attackRange then
				humanoid:MoveTo(root.Position)
				if not busy and now - lastAttackAt >= tier.AttackCooldown then
					lastAttackAt = now
					task.spawn(performAttack, target)
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
-- options.Champion: DungeonService's per-wave modifier - see buildEnemy.
function EnemyService.Spawn(
	kindName: string,
	position: Vector3,
	options: { Respawn: boolean?, Tags: { [string]: any }?, Champion: boolean? }?
)
	options = options or {}
	local respawn = options.Respawn ~= false

	local model = buildEnemy(kindName, options.Champion)
	if options.Tags then
		for attributeName, value in options.Tags do
			model:SetAttribute(attributeName, value)
		end
	end

	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace
	activeEnemies[model] = true

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
		activeEnemies[model] = nil
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
