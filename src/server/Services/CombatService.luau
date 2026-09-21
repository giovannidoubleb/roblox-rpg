--[[
	Server-authoritative basic attack. The client only requests an attack;
	this service decides whether it lands (cooldown, range, facing) and
	applies damage. Skills/ultimate from the design doc are a future pass -
	this wires the basic attack end-to-end first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CombatService = {}

local lastAttackAt: { [Player]: number } = {}

local function findAttackTarget(root: BasePart)
	local attack = Config.Combat.BasicAttack
	local closest, closestDistance = nil, attack.Range

	for _, model in Workspace:GetChildren() do
		if not model:IsA("Model") then
			continue
		end

		local tierName = model:GetAttribute("Tier")
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local enemyRoot = model.PrimaryPart

		if tierName and humanoid and humanoid.Health > 0 and enemyRoot then
			local offset = enemyRoot.Position - root.Position
			local distance = offset.Magnitude

			if distance <= closestDistance then
				local facing = root.CFrame.LookVector
				local toEnemy = offset.Unit
				if facing:Dot(toEnemy) > 0.3 then
					closest, closestDistance = model, distance
				end
			end
		end
	end

	return closest
end

local function onRequestAttack(player: Player)
	local attack = Config.Combat.BasicAttack
	local now = os.clock()

	if (lastAttackAt[player] or 0) + attack.Cooldown > now then
		return
	end
	lastAttackAt[player] = now

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local target = findAttackTarget(root)
	if not target then
		return
	end

	target:SetAttribute("LastDamagedBy", player.UserId)
	local humanoid = target:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid:TakeDamage(attack.Damage)
end

local function onPlayerRemoving(player: Player)
	lastAttackAt[player] = nil
end

function CombatService.Init()
	Remotes.RequestAttack.OnServerEvent:Connect(onRequestAttack)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return CombatService
