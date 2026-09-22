--[[
	Crafting: consume N unequipped items of a rarity, wait out a timer, get
	one guaranteed item of the next rarity up. A banked CraftingRush charge
	(from the developer product of the same name) shortens the very next
	craft's timer instead of instantly finishing whatever's in progress -
	simpler to reason about than retroactively rushing a running timer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local ItemDatabase = require(ReplicatedStorage.Shared.Modules.ItemDatabase)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local CraftingService = {}

local function findRecipe(recipeId: string)
	for _, recipe in Config.Crafting.Recipes do
		if recipe.Id == recipeId then
			return recipe
		end
	end
	return nil
end

-- Unequipped inventory instance ids matching the given rarity.
local function findConsumableInstances(data, rarity: string)
	local matches = {}
	for instanceId, itemId in data.Inventory do
		local item = ItemDatabase.Items[itemId]
		if item and item.Rarity == rarity then
			local isEquipped = false
			for _, equippedInstanceId in data.Equipped do
				if equippedInstanceId == instanceId then
					isEquipped = true
					break
				end
			end
			if not isEquipped then
				table.insert(matches, instanceId)
			end
		end
	end
	return matches
end

local function finalizeCraft(player: Player, recipeId: string)
	local data = PlayerDataService.Get(player)
	if not data or not data.CraftPending or data.CraftPending.RecipeId ~= recipeId then
		return
	end

	local recipe = findRecipe(recipeId)
	data.CraftPending = nil
	if not recipe then
		PlayerDataService.PushUpdate(player)
		return
	end

	local resultItemId = ItemDatabase.PickRandomId(recipe.ResultRarity)
	PlayerDataService.AddInventoryItem(player, resultItemId)
	PlayerDataService.PushUpdate(player)
	Remotes.Notify:FireClient(player, "Crafting complete: " .. ItemDatabase.Items[resultItemId].Name .. "!")
end

local function onRequestCraft(player: Player, recipeId: string)
	local recipe = findRecipe(recipeId)
	if not recipe then
		return
	end

	local data = PlayerDataService.Get(player)
	if not data or data.CraftPending then
		return
	end

	local consumable = findConsumableInstances(data, recipe.ConsumeRarity)
	if #consumable < recipe.ConsumeCount then
		Remotes.Notify:FireClient(player, string.format("Need %d unequipped %s items to craft that.", recipe.ConsumeCount, recipe.ConsumeRarity))
		return
	end

	for i = 1, recipe.ConsumeCount do
		local instanceId = consumable[i]
		data.Inventory[instanceId] = nil
		data.InventoryCount -= 1
	end

	local duration = Config.Crafting.CraftSeconds
	if (data.Consumables.CraftingRush or 0) > 0 then
		data.Consumables.CraftingRush -= 1
		duration = Config.Crafting.RushedCraftSeconds
		Remotes.Notify:FireClient(player, "Crafting Rush charge used - this one's fast.")
	end

	data.CraftPending = { RecipeId = recipe.Id, ReadyAt = os.time() + duration }
	PlayerDataService.PushInventoryUpdate(player)
	PlayerDataService.PushUpdate(player)

	task.delay(duration, function()
		finalizeCraft(player, recipe.Id)
	end)
end

-- If a player disconnects mid-craft, CraftPending is still there (it's part
-- of the persisted profile) when they come back - pick the timer back up
-- instead of leaving the consumed materials in limbo forever.
local function resumeCraftIfPending(player: Player)
	local data = PlayerDataService.Get(player)
	if not data or not data.CraftPending then
		return
	end

	local remaining = data.CraftPending.ReadyAt - os.time()
	local recipeId = data.CraftPending.RecipeId
	if remaining <= 0 then
		finalizeCraft(player, recipeId)
	else
		task.delay(remaining, function()
			finalizeCraft(player, recipeId)
		end)
	end
end

function CraftingService.Init()
	Remotes.RequestCraft.OnServerEvent:Connect(function(player, recipeId)
		if typeof(recipeId) == "string" then
			onRequestCraft(player, recipeId)
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			while player.Parent and not PlayerDataService.Get(player) do
				task.wait(0.5)
			end
			resumeCraftIfPending(player)
		end)
	end)

	for _, player in Players:GetPlayers() do
		resumeCraftIfPending(player)
	end
end

return CraftingService
