--[[
	Game Pass ownership checks and Developer Product purchase handling for
	the items in the "Ledger & Loot" monetization plan. Every id in
	Config.Monetization starts at 0 ("not created yet"); this service skips
	anything still at 0, so it's safe to ship before the passes/products
	exist. Once Giovanni creates them in the Creator Dashboard, filling in
	the real ids in Config.luau turns each one on - no code changes needed.

	Purchases are idempotent: every granted receipt/purchase id is recorded
	in the player's persisted profile (PlayerDataService), so a retried
	ProcessReceipt call (Roblox does this on failure) never double-grants.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local MonetizationService = {}

local PASS_ID_TO_NAME = {}
for passName, id in Config.Monetization.GamePasses do
	if id ~= 0 then
		PASS_ID_TO_NAME[id] = passName
	end
end

local PRODUCT_ID_TO_NAME = {}
for productName, id in Config.Monetization.DeveloperProducts do
	if id ~= 0 then
		PRODUCT_ID_TO_NAME[id] = productName
	end
end

local GEM_POUCHES = {
	GemPouchSmall = true,
	GemPouchMedium = true,
	GemPouchLarge = true,
	GemPouchMega = true,
}

-- Applies what a Developer Product purchase grants. Every product here has
-- a real effect now; SeasonPass is a Developer Product in the "Ledger &
-- Loot" plan but behaves like an unlock (reuses the Passes flag/HasPass
-- plumbing) rather than a stacking consumable.
local function grantProduct(player: Player, productName: string)
	if GEM_POUCHES[productName] then
		PlayerDataService.AddGems(player, Config.Monetization.GemPouchAmounts[productName])
	elseif productName == "InstantReviveToken" or productName == "StatRespecToken" or productName == "CharacterRenameToken" or productName == "ZoneSkipKey" or productName == "CraftingRush" then
		PlayerDataService.AddConsumable(player, productName, 1)
	elseif productName == "MysteryCosmeticCrate" then
		local data = PlayerDataService.Get(player)
		if not data then
			return
		end

		local unowned = {}
		for cosmeticId in Config.Cosmetics.Available do
			if not data.Cosmetics.Owned[cosmeticId] then
				table.insert(unowned, cosmeticId)
			end
		end

		if #unowned > 0 then
			local pick = unowned[math.random(1, #unowned)]
			PlayerDataService.GrantCosmetic(player, pick)
			Remotes.Notify:FireClient(player, "Mystery Crate: unlocked " .. Config.Cosmetics.Available[pick].Name .. "!")
		else
			PlayerDataService.AddGems(player, 150)
			Remotes.Notify:FireClient(player, "Mystery Crate: every cosmetic already owned - +150 gems instead!")
		end
	elseif productName == "SeasonPass" then
		PlayerDataService.GrantPass(player, "SeasonPass")
	end
end

local function waitForProfile(player: Player)
	while player.Parent and not PlayerDataService.Get(player) do
		task.wait(0.5)
	end
	return PlayerDataService.Get(player)
end

local function checkGamePasses(player: Player)
	if not waitForProfile(player) then
		return
	end

	for passName, id in Config.Monetization.GamePasses do
		if id ~= 0 and not PlayerDataService.HasPass(player, passName) then
			local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, id)
			if ok and owns then
				PlayerDataService.GrantPass(player, passName)
			end
		end
	end
end

local function onProcessReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not waitForProfile(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = receiptInfo.PurchaseId
	if PlayerDataService.HasGrantedReceipt(player, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local productName = PRODUCT_ID_TO_NAME[receiptInfo.ProductId]
	if productName then
		grantProduct(player, productName)
	end

	PlayerDataService.MarkReceiptGranted(player, purchaseId)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function MonetizationService.Init()
	MarketplaceService.ProcessReceipt = onProcessReceipt

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then
			return
		end
		local passName = PASS_ID_TO_NAME[gamePassId]
		if passName then
			PlayerDataService.GrantPass(player, passName)
		end
	end)

	Players.PlayerAdded:Connect(checkGamePasses)
	for _, player in Players:GetPlayers() do
		task.spawn(checkGamePasses, player)
	end
end

return MonetizationService
