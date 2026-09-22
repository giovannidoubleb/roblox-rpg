--[[
	Owns each player's persistent RPG data for the session: level/XP,
	health, gems, daily keys/quests/streak, inventory/equipment, owned
	passes, and granted purchase receipts. Backed by PlayerProfileStore
	(DataStore + retry + session lock). All writes to this data happen on
	the server; the client only ever receives read-only snapshots over
	PlayerDataUpdated/InventoryUpdated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local ItemDatabase = require(ReplicatedStorage.Shared.Modules.ItemDatabase)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerProfileStore = require(script.Parent.PlayerProfileStore)

local PlayerDataService = {}

local SAVE_INTERVAL_SECONDS = 120
local REGEN_TICK_SECONDS = 1
local REGEN_DELAY_AFTER_DAMAGE = 5
local REGEN_PERCENT_PER_TICK = 0.02

local profiles: { [Player]: { [string]: any } } = {}

local function defaultData()
	return {
		Level = Config.StartingStats.Level,
		Experience = Config.StartingStats.Experience,
		BaseMaxHealth = Config.StartingStats.MaxHealth,
		MaxHealth = Config.StartingStats.MaxHealth,

		Keys = Config.Daily.KeysPerDay,
		LastKeyRegenAt = os.time(),
		BossKillsSincePity = 0,

		Gems = 0,
		Streak = 0,
		LastClaimDate = "",
		DailyQuests = {},
		DailyQuestsAssignedDate = "",

		Passes = {},
		GrantedReceipts = {},

		Inventory = {},
		InventoryCount = 0,
		NextInstanceId = 1,
		Equipped = {},

		SkillPoints = 0,
		AllocatedSkills = { Damage = 0, Health = 0, CritChance = 0 },

		Consumables = { InstantReviveToken = 0, StatRespecToken = 0, CharacterRenameToken = 0, ZoneSkipKey = 0, CraftingRush = 0 },
		Nickname = "",

		Companions = { Owned = {}, Active = {} },
		Cosmetics = { Owned = {}, Equipped = "" },

		DiscoveredZones = { Hub = true },
		SeasonClaimedTiers = {},
		FounderPerkGranted = false,

		CraftPending = nil,
	}
end

-- Fills in any field a saved profile predates (new systems added after that
-- profile was first written) from a fresh default, without touching what's
-- already there. Recurses into nested tables like Consumables/Companions.
local function backfillDefaults(data, defaults)
	for key, value in defaults do
		if data[key] == nil then
			data[key] = value
		elseif typeof(value) == "table" and typeof(data[key]) == "table" then
			backfillDefaults(data[key], value)
		end
	end
end

local function applyKeyRegen(data)
	local elapsed = os.time() - data.LastKeyRegenAt
	local regenerated = math.floor(elapsed / Config.Daily.KeyRegenSeconds)
	if regenerated > 0 and data.Keys < Config.Daily.KeysPerDay then
		data.Keys = math.min(Config.Daily.KeysPerDay, data.Keys + regenerated)
		data.LastKeyRegenAt += regenerated * Config.Daily.KeyRegenSeconds
	end
end

local function findQuestDef(id: string)
	for _, questDef in Config.Daily.QuestPool do
		if questDef.Id == id then
			return questDef
		end
	end
	return nil
end

local function pushToClient(player: Player)
	local data = profiles[player]
	if data then
		Remotes.PlayerDataUpdated:FireClient(player, data)
	end
end

local function pushInventory(player: Player, data)
	Remotes.InventoryUpdated:FireClient(player, { Inventory = data.Inventory, Equipped = data.Equipped })
end

local function applyMaxHealth(player: Player, data)
	local bonus = 0
	for _, instanceId in data.Equipped do
		local itemId = data.Inventory[instanceId]
		local item = itemId and ItemDatabase.Items[itemId]
		if item then
			bonus += item.HealthBonus or 0
		end
	end
	bonus += data.AllocatedSkills.Health * Config.SkillTree.HealthPerPoint
	data.MaxHealth = data.BaseMaxHealth + bonus

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MaxHealth ~= data.MaxHealth then
		local delta = data.MaxHealth - humanoid.MaxHealth
		humanoid.MaxHealth = data.MaxHealth
		humanoid.Health = math.clamp(humanoid.Health + delta, 1, data.MaxHealth)
	end
end

function PlayerDataService.Get(player: Player)
	return profiles[player]
end

function PlayerDataService.HasPass(player: Player, passName: string): boolean
	local data = profiles[player]
	return data ~= nil and data.Passes[passName] == true
end

function PlayerDataService.GetWeaponDamageBonus(player: Player): number
	local data = profiles[player]
	if not data then
		return 0
	end

	local weaponInstanceId = data.Equipped.Weapon
	if not weaponInstanceId then
		return 0
	end

	local itemId = data.Inventory[weaponInstanceId]
	local item = itemId and ItemDatabase.Items[itemId]
	return item and item.DamageBonus or 0
end

function PlayerDataService.AddExperience(player: Player, amount: number)
	local data = profiles[player]
	if not data or amount <= 0 then
		return
	end

	if data.Passes.DoubleXp then
		amount *= 2
	end
	if data.Passes.FoundersPass then
		amount = math.floor(amount * Config.Monetization.FounderXpBoost)
	end

	data.Experience += amount

	while data.Level < Config.Leveling.MaxLevel do
		local xpToNext = Config.GetXpToNextLevel(data.Level)
		if data.Experience < xpToNext then
			break
		end

		data.Experience -= xpToNext
		data.Level += 1
		data.BaseMaxHealth += Config.Leveling.HealthPerLevel
		data.SkillPoints += Config.SkillTree.PointsPerLevel
		Remotes.LevelUp:FireClient(player, data.Level)
	end

	if data.Level >= Config.Leveling.MaxLevel then
		data.Experience = 0
	end

	applyMaxHealth(player, data)
	pushToClient(player)
end

function PlayerDataService.AddGems(player: Player, amount: number)
	local data = profiles[player]
	if not data or amount == 0 then
		return
	end

	data.Gems = math.max(0, data.Gems + amount)
	pushToClient(player)
end

-- Peeks whether this player's next boss kill is pity-guaranteed, without
-- mutating the counter. Call before rolling the chest so the roll can be
-- forced to Epic+.
function PlayerDataService.PeekPity(player: Player): boolean
	local data = profiles[player]
	return data ~= nil and data.BossKillsSincePity >= Config.Pity.BossKillThreshold
end

-- Advances or resets the pity counter given whether this boss kill's drop
-- was Epic-or-better (naturally or via pity). Call once per boss kill,
-- right after rolling loot.
function PlayerDataService.RegisterBossKill(player: Player, gotEpicOrBetter: boolean): boolean
	local data = profiles[player]
	if not data then
		return false
	end

	local forcedPity = data.BossKillsSincePity >= Config.Pity.BossKillThreshold

	if gotEpicOrBetter or forcedPity then
		data.BossKillsSincePity = 0
	else
		data.BossKillsSincePity += 1
	end

	pushToClient(player)
	return forcedPity
end

function PlayerDataService.SpendKey(player: Player): boolean
	local data = profiles[player]
	if not data or data.Keys <= 0 then
		return false
	end

	data.Keys -= 1
	pushToClient(player)
	return true
end

function PlayerDataService.AddInventoryItem(player: Player, itemId: string): string?
	local data = profiles[player]
	if not data then
		return nil
	end

	local cap = Config.Inventory.BaseSlots
		+ (PlayerDataService.HasPass(player, "BackpackExpansion") and Config.Inventory.BackpackExpansionBonusSlots or 0)

	if data.InventoryCount >= cap then
		Remotes.Notify:FireClient(player, "Inventory full - clear space or grab a Backpack Expansion.")
		return nil
	end

	local instanceId = tostring(data.NextInstanceId)
	data.NextInstanceId += 1
	data.Inventory[instanceId] = itemId
	data.InventoryCount += 1

	pushInventory(player, data)
	return instanceId
end

function PlayerDataService.EquipItem(player: Player, instanceId: string): boolean
	local data = profiles[player]
	if not data then
		return false
	end

	local itemId = data.Inventory[instanceId]
	local item = itemId and ItemDatabase.Items[itemId]
	if not item then
		return false
	end

	data.Equipped[item.Slot] = instanceId
	applyMaxHealth(player, data)
	pushInventory(player, data)
	pushToClient(player)
	return true
end

-- Generic re-push helpers so sibling services (skill tree, crafting,
-- companions, cosmetics, season, zones) can mutate the profile table
-- returned by PlayerDataService.Get directly and then notify the client,
-- the same way this module's own methods do.
function PlayerDataService.PushUpdate(player: Player)
	pushToClient(player)
end

function PlayerDataService.PushInventoryUpdate(player: Player)
	local data = profiles[player]
	if data then
		pushInventory(player, data)
	end
end

function PlayerDataService.GetSkillDamageBonus(player: Player): number
	local data = profiles[player]
	return data and data.AllocatedSkills.Damage * Config.SkillTree.DamagePerPoint or 0
end

function PlayerDataService.GetCritChance(player: Player): number
	local data = profiles[player]
	return data and data.AllocatedSkills.CritChance * Config.SkillTree.CritChancePerPoint or 0
end

function PlayerDataService.AllocateSkillPoint(player: Player, statName: string): boolean
	local data = profiles[player]
	if not data or not Config.SkillTree.Stats[statName] then
		return false
	end
	if data.SkillPoints <= 0 then
		return false
	end

	data.SkillPoints -= 1
	data.AllocatedSkills[statName] += 1

	if statName == "Health" then
		applyMaxHealth(player, data)
	end

	pushToClient(player)
	return true
end

function PlayerDataService.RespecSkills(player: Player): boolean
	local data = profiles[player]
	if not data or (data.Consumables.StatRespecToken or 0) <= 0 then
		return false
	end

	local refunded = 0
	for statName, points in data.AllocatedSkills do
		refunded += points
		data.AllocatedSkills[statName] = 0
	end

	if refunded == 0 then
		return false
	end

	data.Consumables.StatRespecToken -= 1
	data.SkillPoints += refunded
	applyMaxHealth(player, data)
	pushToClient(player)
	Remotes.Notify:FireClient(player, "Skills reset - " .. refunded .. " points refunded.")
	return true
end

function PlayerDataService.AddConsumable(player: Player, name: string, amount: number)
	local data = profiles[player]
	if not data or amount == 0 then
		return
	end

	data.Consumables[name] = (data.Consumables[name] or 0) + amount
	pushToClient(player)
end

-- Instant Revive: if the player is holding a token when they die, skip the
-- normal walk-back-from-spawn respawn and drop them back at their death
-- spot at full health a moment later instead.
function PlayerDataService.HandleDeath(player: Player)
	local data = profiles[player]
	if not data or (data.Consumables.InstantReviveToken or 0) <= 0 then
		return
	end

	local character = player.Character
	local deathCFrame = character and character.PrimaryPart and character.PrimaryPart.CFrame
	if not deathCFrame then
		return
	end

	data.Consumables.InstantReviveToken -= 1
	pushToClient(player)

	task.delay(1.5, function()
		if not player.Parent then
			return
		end

		player:LoadCharacter()

		local newCharacter = player.Character
		if not newCharacter then
			return
		end

		local hrp = newCharacter:FindFirstChild("HumanoidRootPart") or newCharacter:WaitForChild("HumanoidRootPart", 5)
		if hrp then
			hrp.CFrame = deathCFrame + Vector3.new(0, 3, 0)
		end

		Remotes.Notify:FireClient(player, "Instant Revive Token used - back in the fight!")
	end)
end

function PlayerDataService.SetNickname(player: Player, rawName: string): boolean
	local data = profiles[player]
	if not data or (data.Consumables.CharacterRenameToken or 0) <= 0 then
		return false
	end

	local trimmed = rawName:sub(1, 20)
	if #trimmed < 1 then
		return false
	end

	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(trimmed, player.UserId)
		return result:GetNonChatStringForBroadcastAsync()
	end)

	if not ok or not filtered or #filtered < 1 then
		Remotes.Notify:FireClient(player, "That name couldn't be used - try something else.")
		return false
	end

	data.Consumables.CharacterRenameToken -= 1
	data.Nickname = filtered
	player:SetAttribute("Nickname", filtered)
	pushToClient(player)
	PlayerProfileStore.Save(player.UserId, data)
	return true
end

function PlayerDataService.GetCompanionSlotCount(player: Player): number
	return Config.Companions.BaseSlots + (PlayerDataService.HasPass(player, "CompanionSlotExpansion") and Config.Companions.ExpansionBonusSlots or 0)
end

function PlayerDataService.PurchaseCompanion(player: Player, companionId: string): boolean
	local data = profiles[player]
	local def = Config.Companions.Available[companionId]
	if not data or not def or data.Companions.Owned[companionId] then
		return false
	end

	if data.Gems < def.GemCost then
		Remotes.Notify:FireClient(player, "Not enough gems for that companion.")
		return false
	end

	data.Gems -= def.GemCost
	data.Companions.Owned[companionId] = true
	pushToClient(player)
	return true
end

function PlayerDataService.SetActiveCompanions(player: Player, companionIds: { string }): boolean
	local data = profiles[player]
	if not data then
		return false
	end

	local slots = PlayerDataService.GetCompanionSlotCount(player)
	if #companionIds > slots then
		Remotes.Notify:FireClient(player, "You don't have enough companion slots for that.")
		return false
	end

	for _, companionId in companionIds do
		if not data.Companions.Owned[companionId] then
			return false
		end
	end

	data.Companions.Active = companionIds
	pushToClient(player)
	return true
end

-- Unconditional grant (Mystery Crate). See PurchaseCosmeticWithGems for the
-- merchant's pay-for-a-specific-one path.
function PlayerDataService.GrantCosmetic(player: Player, cosmeticId: string)
	local data = profiles[player]
	if not data or not Config.Cosmetics.Available[cosmeticId] then
		return
	end

	data.Cosmetics.Owned[cosmeticId] = true
	pushToClient(player)
end

function PlayerDataService.PurchaseCosmeticWithGems(player: Player, cosmeticId: string): boolean
	local data = profiles[player]
	local def = Config.Cosmetics.Available[cosmeticId]
	if not data or not def or data.Cosmetics.Owned[cosmeticId] then
		return false
	end

	if data.Gems < def.GemCost then
		Remotes.Notify:FireClient(player, "Not enough gems for that cosmetic.")
		return false
	end

	data.Gems -= def.GemCost
	data.Cosmetics.Owned[cosmeticId] = true
	pushToClient(player)
	return true
end

function PlayerDataService.EquipCosmetic(player: Player, cosmeticId: string): boolean
	local data = profiles[player]
	if not data then
		return false
	end

	if cosmeticId ~= "" and not data.Cosmetics.Owned[cosmeticId] then
		return false
	end

	data.Cosmetics.Equipped = cosmeticId
	player:SetAttribute("Cosmetic", cosmeticId)
	pushToClient(player)
	return true
end

function PlayerDataService.DiscoverZone(player: Player, zoneName: string)
	local data = profiles[player]
	if not data then
		return
	end

	if not data.DiscoveredZones[zoneName] then
		data.DiscoveredZones[zoneName] = true
		pushToClient(player)
	end
end

function PlayerDataService.ClaimSeasonTier(player: Player, tierIndex: number): boolean
	local data = profiles[player]
	local tier = Config.Season.Tiers[tierIndex]
	if not data or not tier then
		return false
	end

	if not PlayerDataService.HasPass(player, "SeasonPass") then
		Remotes.Notify:FireClient(player, "Season Pass required to claim season rewards.")
		return false
	end

	if data.Level < tier.Level then
		return false
	end

	if data.SeasonClaimedTiers[tostring(tierIndex)] then
		return false
	end

	data.SeasonClaimedTiers[tostring(tierIndex)] = true
	PlayerDataService.AddGems(player, tier.Gems)
	Remotes.Notify:FireClient(player, string.format("Season tier %d claimed: +%d gems!", tierIndex, tier.Gems))
	pushToClient(player)
	return true
end

-- One-time Founder's Pass bonus (gems), on top of the permanent XP boost
-- that AddExperience applies for as long as the pass is owned. Called both
-- on purchase and on join (in case the pass was bought outside a live
-- session and never got its one-time grant).
function PlayerDataService.ApplyFounderPerkIfNeeded(player: Player)
	local data = profiles[player]
	if not data or data.FounderPerkGranted or not data.Passes.FoundersPass then
		return
	end

	data.FounderPerkGranted = true
	PlayerDataService.AddGems(player, Config.Monetization.FounderBonusGems)
	Remotes.Notify:FireClient(player, string.format("Founder's Pass bonus: +%d gems!", Config.Monetization.FounderBonusGems))
end

function PlayerDataService.EnsureDailyQuests(player: Player)
	local data = profiles[player]
	if not data then
		return
	end

	local today = os.date("!%Y-%m-%d")
	if data.DailyQuestsAssignedDate == today then
		return
	end

	local pool = table.clone(Config.Daily.QuestPool)
	local picked = {}
	for _ = 1, math.min(Config.Daily.QuestCount, #pool) do
		local index = math.random(1, #pool)
		table.insert(picked, table.remove(pool, index))
	end

	data.DailyQuests = {}
	for _, questDef in picked do
		table.insert(data.DailyQuests, { Id = questDef.Id, Progress = 0, Completed = false })
	end
	data.DailyQuestsAssignedDate = today

	pushToClient(player)
end

-- "Any" quests only count enemy kills, not other events (like completing
-- the dungeon) that also report progress through this function.
local KILL_TIERS = { Trash = true, Elite = true, Boss = true }

-- tierName: "Trash" | "Elite" | "Boss" | "Dungeon" (dungeon-run completion,
-- reported separately from the kill that finishes it).
function PlayerDataService.ReportQuestProgress(player: Player, tierName: string, amount: number?)
	local data = profiles[player]
	if not data then
		return
	end

	amount = amount or 1
	local changed = false
	local matchesAny = KILL_TIERS[tierName] == true

	for _, quest in data.DailyQuests do
		if not quest.Completed then
			local questDef = findQuestDef(quest.Id)
			if questDef and (questDef.Tier == tierName or (matchesAny and questDef.Tier == "Any")) then
				quest.Progress = math.min(questDef.Target, quest.Progress + amount)
				changed = true

				if quest.Progress >= questDef.Target then
					quest.Completed = true
					PlayerDataService.AddExperience(player, questDef.XpReward)
					PlayerDataService.AddGems(player, questDef.GemReward)
					Remotes.Notify:FireClient(
						player,
						string.format("Quest complete: %s (+%d XP, +%d gems)", questDef.Description, questDef.XpReward, questDef.GemReward)
					)
				end
			end
		end
	end

	if changed then
		pushToClient(player)
	end
end

function PlayerDataService.ClaimDailyLogin(player: Player)
	local data = profiles[player]
	if not data then
		return
	end

	local today = os.date("!%Y-%m-%d")
	if data.LastClaimDate == today then
		Remotes.Notify:FireClient(player, "Already claimed today's login bonus.")
		return
	end

	local yesterday = os.date("!%Y-%m-%d", os.time() - 24 * 60 * 60)
	if data.LastClaimDate == yesterday then
		data.Streak = (data.Streak % #Config.Daily.StreakRewardGems) + 1
	else
		data.Streak = 1
	end

	data.LastClaimDate = today
	local reward = Config.Daily.StreakRewardGems[data.Streak]
	PlayerDataService.AddGems(player, reward)
	Remotes.Notify:FireClient(player, string.format("Day %d streak claimed: +%d gems!", data.Streak, reward))
	pushToClient(player)
end

function PlayerDataService.GrantPass(player: Player, passName: string)
	local data = profiles[player]
	if not data then
		return
	end

	data.Passes[passName] = true
	pushToClient(player)

	if passName == "FoundersPass" then
		PlayerDataService.ApplyFounderPerkIfNeeded(player)
	end

	PlayerProfileStore.Save(player.UserId, data)
end

function PlayerDataService.HasGrantedReceipt(player: Player, purchaseId: string): boolean
	local data = profiles[player]
	return data ~= nil and data.GrantedReceipts[purchaseId] == true
end

function PlayerDataService.MarkReceiptGranted(player: Player, purchaseId: string)
	local data = profiles[player]
	if not data then
		return
	end

	data.GrantedReceipts[purchaseId] = true
	PlayerProfileStore.Save(player.UserId, data)
end

-- Slow out-of-combat regen so a rough pull isn't a death spiral while the
-- player walks back to safety. Stops the moment the character dies or is
-- replaced (loop exits on its own next tick via the humanoid/parent check).
local function runRegen(character: Model, humanoid: Humanoid)
	local lastDamageAt = os.clock()
	humanoid.HealthChanged:Connect(function()
		lastDamageAt = os.clock()
	end)

	while character.Parent and humanoid.Health > 0 do
		task.wait(REGEN_TICK_SECONDS)
		if not character.Parent or humanoid.Health <= 0 then
			break
		end

		if os.clock() - lastDamageAt >= REGEN_DELAY_AFTER_DAMAGE and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * REGEN_PERCENT_PER_TICK)
		end
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local data = profiles[player]
	if not data then
		return
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = data.MaxHealth
	humanoid.Health = data.MaxHealth

	humanoid.Died:Connect(function()
		Remotes.PlayerDied:FireClient(player)
		PlayerDataService.HandleDeath(player)
	end)

	task.spawn(runRegen, character, humanoid)
end

local function onPlayerAdded(player: Player)
	local data, err = PlayerProfileStore.Load(player.UserId, defaultData())

	if not data then
		warn(string.format("[PlayerDataService] failed to load profile for %s: %s", player.Name, tostring(err)))
		player:Kick("Could not load your save data. Please rejoin in a moment.")
		return
	end

	backfillDefaults(data, defaultData())
	applyKeyRegen(data)
	profiles[player] = data
	PlayerDataService.EnsureDailyQuests(player)
	PlayerDataService.ApplyFounderPerkIfNeeded(player)
	player:SetAttribute("Nickname", data.Nickname)
	player:SetAttribute("Cosmetic", data.Cosmetics.Equipped)
	pushToClient(player)
	pushInventory(player, data)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local data = profiles[player]
	if not data then
		return
	end

	PlayerProfileStore.Save(player.UserId, data)
	PlayerProfileStore.ReleaseLock(player.UserId)
	profiles[player] = nil
end

function PlayerDataService.Init()
	Remotes.ClaimDailyLogin.OnServerEvent:Connect(function(player)
		PlayerDataService.ClaimDailyLogin(player)
	end)

	Remotes.EquipItem.OnServerEvent:Connect(function(player, instanceId)
		if typeof(instanceId) == "string" then
			PlayerDataService.EquipItem(player, instanceId)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL_SECONDS)
			for player, data in profiles do
				PlayerProfileStore.Save(player.UserId, data)
			end
		end
	end)

	game:BindToClose(function()
		for player, data in profiles do
			PlayerProfileStore.Save(player.UserId, data)
			PlayerProfileStore.ReleaseLock(player.UserId)
		end
	end)
end

return PlayerDataService
