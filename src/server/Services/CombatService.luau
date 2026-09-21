--[[
	Server-authoritative combat: basic attack, the two active skills, and
	the ultimate. The client only requests an action; this service decides
	whether it lands (cooldown, range, facing) and applies damage.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CombatService = {}

local lastAttackAt: { [Player]: number } = {}
local lastSkillAt: { [Player]: { [string]: number } } = {}
local ultimateMeter: { [Player]: number } = {}

local function livingEnemies()
	local enemies = {}
	for _, model in Workspace:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Tier") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and model.PrimaryPart then
				table.insert(enemies, model)
			end
		end
	end
	return enemies
end

local function damageEnemy(enemy: Model, player: Player, damage: number)
	enemy:SetAttribute("LastDamagedBy", player.UserId)
	local humanoid = enemy:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid:TakeDamage(damage)
end

-- Closest enemy within range, in front of root (frontal cone). Used by the
-- basic attack and single-target skills.
local function findFrontalTarget(root: BasePart, range: number)
	local closest, closestDistance = nil, range

	for _, enemy in livingEnemies() do
		local offset = (enemy.PrimaryPart.Position - root.Position)
		local distance = offset.Magnitude
		if distance <= closestDistance then
			local toEnemy = offset.Unit
			if root.CFrame.LookVector:Dot(toEnemy) > 0.3 then
				closest, closestDistance = enemy, distance
			end
		end
	end

	return closest
end

-- All enemies within range, in front of root (used by Cleave).
local function findFrontalTargets(root: BasePart, range: number)
	local hits = {}
	for _, enemy in livingEnemies() do
		local offset = (enemy.PrimaryPart.Position - root.Position)
		if offset.Magnitude <= range then
			if root.CFrame.LookVector:Dot(offset.Unit) > 0.3 then
				table.insert(hits, enemy)
			end
		end
	end
	return hits
end

-- All enemies within radius of root, any direction (used by the ultimate).
local function findRadiusTargets(root: BasePart, radius: number)
	local hits = {}
	for _, enemy in livingEnemies() do
		if (enemy.PrimaryPart.Position - root.Position).Magnitude <= radius then
			table.insert(hits, enemy)
		end
	end
	return hits
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function addUltimateMeter(player: Player, amount: number)
	local meter = math.clamp((ultimateMeter[player] or 0) + amount, 0, Config.Combat.Ultimate.MeterMax)
	ultimateMeter[player] = meter
	Remotes.UltimateMeterUpdated:FireClient(player, meter, Config.Combat.Ultimate.MeterMax)
end

local function onRequestAttack(player: Player)
	local attack = Config.Combat.BasicAttack
	local now = os.clock()

	if (lastAttackAt[player] or 0) + attack.Cooldown > now then
		return
	end
	lastAttackAt[player] = now

	local root = getCharacterRoot(player)
	if not root then
		return
	end

	local target = findFrontalTarget(root, attack.Range)
	if not target then
		return
	end

	damageEnemy(target, player, attack.Damage + PlayerDataService.GetWeaponDamageBonus(player))
	addUltimateMeter(player, Config.Combat.Ultimate.MeterPerBasicAttack)
end

local function onRequestSkill(player: Player, skillName: string)
	local skill = Config.Combat.Skills[skillName]
	if not skill then
		return
	end

	local cooldowns = lastSkillAt[player]
	if not cooldowns then
		cooldowns = {}
		lastSkillAt[player] = cooldowns
	end

	local now = os.clock()
	if (cooldowns[skillName] or 0) + skill.Cooldown > now then
		return
	end

	local root = getCharacterRoot(player)
	if not root then
		return
	end

	local bonus = PlayerDataService.GetWeaponDamageBonus(player)

	if skillName == "Cleave" then
		local targets = findFrontalTargets(root, skill.Range)
		if #targets == 0 then
			return
		end
		cooldowns[skillName] = now
		for _, enemy in targets do
			damageEnemy(enemy, player, skill.Damage + bonus)
		end
	else
		local target = findFrontalTarget(root, skill.Range)
		if not target then
			return
		end
		cooldowns[skillName] = now
		damageEnemy(target, player, skill.Damage + bonus)
	end
end

local function onRequestUltimate(player: Player)
	local ultimate = Config.Combat.Ultimate
	if (ultimateMeter[player] or 0) < ultimate.MeterMax then
		return
	end

	local root = getCharacterRoot(player)
	if not root then
		return
	end

	local targets = findRadiusTargets(root, ultimate.Radius)
	if #targets == 0 then
		return
	end

	ultimateMeter[player] = 0
	Remotes.UltimateMeterUpdated:FireClient(player, 0, ultimate.MeterMax)

	local bonus = PlayerDataService.GetWeaponDamageBonus(player)
	for _, enemy in targets do
		damageEnemy(enemy, player, ultimate.Damage + bonus)
	end
end

local function onPlayerRemoving(player: Player)
	lastAttackAt[player] = nil
	lastSkillAt[player] = nil
	ultimateMeter[player] = nil
end

function CombatService.Init()
	Remotes.RequestAttack.OnServerEvent:Connect(onRequestAttack)
	Remotes.RequestSkill.OnServerEvent:Connect(function(player, skillName)
		if typeof(skillName) == "string" then
			onRequestSkill(player, skillName)
		end
	end)
	Remotes.RequestUltimate.OnServerEvent:Connect(onRequestUltimate)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return CombatService
