-- CITY GRIND: shops and character customization (sections 1, 49, 74-77, 110).
--
--   Threads Clothing   catalog clothes + accessories, try-on, buy, equip
--   Fresh Cuts Barber  sit in a chair, pick hair / colour / facial hair, pay
--   Corner Mart        drinks + snacks (stamina refills, buffs, protein)
--   Mama's Kitchen     order at the counter, sit at a table, eat (Well Fed)
--   Closet             owned items, 3 outfit slots, "use my Roblox avatar"
--
-- The server owns everything: prices come from ShopsConfig, purchases need the
-- player inside that shop's interior, equips need ownership, and the look is
-- rebuilt on the server (ShopsConfig.Look) every time it changes and on every
-- spawn so everyone sees the same thing.
--
-- Remotes (ReplicatedStorage.CityGrind.Remotes):
--   ShopGetState  RemoteFunction  client -> server: () -> state
--   ShopAction    RemoteFunction  client -> server: (action, ...) -> { ok, msg, state }
--   ShopOpen      RemoteEvent     server -> client: (mode, options) open a shop panel
-- Player attributes:
--   StaminaBoostUntil (os.time) Hydrated / Energized buff end
--   WellFedUntil      (os.time) Well Fed buff end
--   MealPending       (string)  meal name being carried in Mama's Kitchen, "" if none
--   UseRobloxAvatar   (bool)    wardrobe toggle mirror

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))
local ShopsConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("ShopsConfig"))

local Look = ShopsConfig.Look
local ITEMS = ShopsConfig.ITEMS
local INTERIORS = ShopsConfig.INTERIORS
-- ShopsConfig.INTERIORS key -> Places.REGIONS key
local REGION_KEYS = { Threads = "Threads", Barber = "Barber", Mart = "CornerMart", Kitchen = "Kitchen" }

local Shops = {}

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
PlayerData.registerSection("wardrobe", function()
	local equipped, colours = {}, {}
	for _, slot in ShopsConfig.SLOTS do
		equipped[slot] = ShopsConfig.STARTER[slot] or ""
		colours[slot] = 1
	end
	return {
		owned = { ShopsConfig.STARTER.top, ShopsConfig.STARTER.bottom, ShopsConfig.STARTER.shoes },
		equipped = equipped, -- slot -> item id ("" = nothing)
		colours = colours, -- slot -> variant index
		hair = "", -- barber style id ("" = the avatar's own hair)
		hairColor = "black",
		facial = "",
		outfits = {
			{ name = "Outfit 1", saved = false, equipped = {}, colours = {} },
			{ name = "Outfit 2", saved = false, equipped = {}, colours = {} },
			{ name = "Outfit 3", saved = false, equipped = {}, colours = {} },
		},
		useRobloxAvatar = false,
		firstPurchase = false,
		proteinAt = 0,
	}
end)

PlayerData.onPublish(function(player, data)
	local w = data.sections and data.sections.wardrobe
	if w then
		player:SetAttribute("UseRobloxAvatar", w.useRobloxAvatar == true)
	end
end)

local function wardrobe(player: Player): any
	return PlayerData.section(player, "wardrobe")
end

local function owns(w: any, id: string): boolean
	return table.find(w.owned, id) ~= nil
end

local function lookOf(w: any): ShopsConfig.LookData
	return { equipped = w.equipped, colours = w.colours, hair = w.hair, hairColor = w.hairColor, facial = w.facial }
end

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local ShopGetState = Net.remote("RemoteFunction", "ShopGetState")
local ShopAction = Net.remote("RemoteFunction", "ShopAction")
local ShopOpen = Net.remote("RemoteEvent", "ShopOpen")
local StaminaRefill = Net.remote("RemoteEvent", "StaminaRefill")

---------------------------------------------------------------------------
-- Applying looks to characters
---------------------------------------------------------------------------
local realDescriptions: { [Player]: HumanoidDescription } = {}
local spawnDescriptions: { [Player]: HumanoidDescription } = {}
local applying: { [Player]: boolean } = {}
local applyAgain: { [Player]: boolean } = {}

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function hideAccessory(accessory: Accessory)
	accessory:SetAttribute("CGHidden", true)
	for _, d in accessory:GetDescendants() do
		if d:IsA("BasePart") then
			if d:GetAttribute("CGOrigT") == nil then
				d:SetAttribute("CGOrigT", d.Transparency)
			end
			d.Transparency = 1
		end
	end
end

local function unhideAccessory(accessory: Accessory)
	accessory:SetAttribute("CGHidden", nil)
	for _, d in accessory:GetDescendants() do
		if d:IsA("BasePart") then
			local original = d:GetAttribute("CGOrigT")
			if type(original) == "number" then
				d.Transparency = original
			end
			d:SetAttribute("CGOrigT", nil)
		end
	end
end

-- Removes every CITY GRIND piece and un-hides the avatar's own accessories.
local function clearLook(character: Model)
	for _, child in character:GetChildren() do
		if child.Name == "CityGrindLook" and child:IsA("Folder") then
			child:Destroy()
		elseif child:IsA("Accessory") then
			if child:GetAttribute("CityGrind") then
				child:Destroy()
			elseif child:GetAttribute("CGHidden") then
				unhideAccessory(child)
			end
		end
	end
end

local function stripClothing(character: Model)
	for _, child in character:GetChildren() do
		local clothing = child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") or child:IsA("BodyColors")
		local layered = child:IsA("Accessory") and not child:GetAttribute("CityGrind") and Look.isLayeredClothing(child)
		if clothing or layered then
			child:Destroy()
		end
	end
end

-- Body part colours as the server set them, so a client can undo its preview.
local function stampColours(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			child:SetAttribute("CGColor", child.Color)
			child:SetAttribute("CGMat", child.Material.Name)
		end
	end
end

local function realDescription(player: Player): HumanoidDescription?
	if realDescriptions[player] then
		return realDescriptions[player]
	end
	if player.UserId > 0 then
		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(player.UserId)
		end)
		if ok and desc then
			realDescriptions[player] = desc
			return desc
		end
	end
	return spawnDescriptions[player] -- Studio test players / web failure
end

local function applyRobloxAvatar(player: Player, humanoid: Humanoid)
	local desc = realDescription(player)
	if not desc then
		Net.notify(player, "CLOSET", "Couldn't load your Roblox avatar right now. Try again in a moment.")
		return
	end
	local ok = pcall(function()
		(humanoid :: any):ApplyDescriptionReset(desc:Clone())
	end)
	if not ok then
		-- Older API: clear clothing/accessories first so everything is re-added.
		pcall(function()
			local blank = desc:Clone()
			blank.Shirt = 0
			blank.Pants = 0
			blank.GraphicTShirt = 0
			blank:SetAccessories({}, true)
			humanoid:ApplyDescription(blank)
			humanoid:ApplyDescription(desc:Clone())
		end)
	end
end

local function applyNow(player: Player, fresh: boolean)
	local w = wardrobe(player)
	local character = player.Character
	local humanoid = humanoidOf(player)
	if not w or not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	if w.useRobloxAvatar then
		clearLook(character)
		if not fresh then
			applyRobloxAvatar(player, humanoid)
		end
	else
		clearLook(character)
		local folder = Instance.new("Folder")
		folder.Name = "CityGrindLook"
		folder.Parent = character
		Look.build(character, lookOf(w), {
			isServer = true,
			folder = folder,
			playerName = player.DisplayName,
			strip = stripClothing,
			hide = hideAccessory,
			setColor = function(part: BasePart, color: Color3, mat: Enum.Material)
				part.Color = color
				part.Material = mat
			end,
		})
	end
	if player.Character == character then
		stampColours(character)
	end
end

-- Rebuilds the player's look. Calls made while one is running are merged.
local function applyLook(player: Player, fresh: boolean?)
	if applying[player] then
		applyAgain[player] = true
		return
	end
	applying[player] = true
	local ok, err = pcall(applyNow, player, fresh == true)
	if not ok then
		warn("[CityGrind] Shops: applying look failed:", err)
	end
	while applyAgain[player] and player.Parent do
		applyAgain[player] = false
		ok, err = pcall(applyNow, player, false)
		if not ok then
			warn("[CityGrind] Shops: applying look failed:", err)
		end
	end
	applying[player] = nil
end

local function refreshLook(player: Player)
	task.spawn(applyLook, player)
end

local function onCharacter(player: Player, character: Model)
	-- Wait for Roblox to finish putting the avatar on, then for the save.
	local deadline = os.clock() + 10
	while not player:HasAppearanceLoaded() and os.clock() < deadline and player.Character == character do
		task.wait(0.1)
	end
	while not PlayerData.isLoaded(player) and player.Parent and player.Character == character do
		task.wait(0.25)
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if player.Character ~= character or not humanoid then
		return
	end
	if not spawnDescriptions[player] then
		local ok, desc = pcall(function()
			return humanoid:GetAppliedDescription()
		end)
		if ok and desc then
			spawnDescriptions[player] = desc
		end
	end
	-- Anything the avatar loader adds later (clothes, layered clothing) is removed
	-- again while a CITY GRIND outfit is worn.
	character.ChildAdded:Connect(function(child)
		local w = wardrobe(player)
		if not w or w.useRobloxAvatar or applying[player] then
			return
		end
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") then
			task.defer(child.Destroy, child)
		elseif child:IsA("Accessory") and not child:GetAttribute("CityGrind") then
			task.defer(function()
				if Look.isLayeredClothing(child) then
					child:Destroy()
				elseif child.Parent == character and Look.accessorySlot(child) then
					refreshLook(player) -- may need hiding behind a CITY GRIND hat/hair
				end
			end)
		end
	end)
	applyLook(player, true)
end

---------------------------------------------------------------------------
-- Money helpers
---------------------------------------------------------------------------
local function cash(n: number): string
	local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if s:sub(1, 1) == "," then
		s = s:sub(2)
	end
	return "$" .. s
end

-- Spends cash and handles the "FIRST PURCHASE" milestone (section 110).
local function charge(player: Player, amount: number, label: string): boolean
	if not PlayerData.spendCash(player, amount, label) then
		Net.notify(player, "NOT ENOUGH CASH", "You need " .. cash(amount) .. " for that.")
		return false
	end
	local w = wardrobe(player)
	if w and not w.firstPurchase then
		w.firstPurchase = true
		PlayerData.markChanged(player)
		Net.notify(player, "FIRST PURCHASE", "Your first buy in the city. +25 XP")
		PlayerData.addXP(player, 25)
	end
	return true
end

local function inShop(player: Player, key: string): boolean
	if player:GetAttribute("Interior") ~= INTERIORS[key] then
		return false
	end
	local region = Places.REGIONS[REGION_KEYS[key]]
	return region ~= nil and Net.distance(player, region) < 100 and Net.alive(player)
end

-- Seated in something that isn't one of our chairs (a car, a bench...).
local function seatedElsewhere(player: Player): boolean
	local humanoid = humanoidOf(player)
	local seat = humanoid and humanoid.SeatPart
	return seat ~= nil and not seat:GetAttribute("BarberChair") and not seat:GetAttribute("KitchenSeat")
end

---------------------------------------------------------------------------
-- Food and drink
---------------------------------------------------------------------------
local function consume(player: Player, food: ShopsConfig.Food, scale: number)
	if food.refill then
		StaminaRefill:FireClient(player)
	end
	local now = os.time()
	if food.boost then
		local current = player:GetAttribute("StaminaBoostUntil") or 0
		player:SetAttribute("StaminaBoostUntil", math.max(current, now + math.floor(food.boost * scale)))
	end
	if food.wellFed then
		local current = player:GetAttribute("WellFedUntil") or 0
		player:SetAttribute("WellFedUntil", math.max(current, now + math.floor(food.wellFed * scale)))
	end
	if food.strengthXP then
		PlayerData.addStatXP(player, "Strength", food.strengthXP)
	end
end

type PendingMeal = { def: ShopsConfig.Meal, plate: Model?, eating: boolean }
local meals: { [Player]: PendingMeal } = {}
local kitchenFolder: Instance? = nil
local kitchenCounter: Vector3 = Vector3.zero

local function makePlate(def: ShopsConfig.Meal): Model
	local model = Instance.new("Model")
	model.Name = "MealPlate"
	local plate = Instance.new("Part")
	plate.Name = "Plate"
	plate.Shape = Enum.PartType.Cylinder
	plate.Size = Vector3.new(0.12, 1.7, 1.7)
	plate.CFrame = CFrame.Angles(0, 0, math.pi / 2)
	plate.Color = Color3.fromRGB(245, 245, 240)
	plate.Material = Enum.Material.SmoothPlastic
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CanTouch = false
	plate.Massless = true
	plate.Parent = model
	model.PrimaryPart = plate
	for _, spec in def.pieces do
		local p = Instance.new("Part")
		p.Name = "Food"
		p.Shape = if spec.shape == "Ball" then Enum.PartType.Ball elseif spec.shape == "Cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
		local size = spec.size
		if spec.shape == "Cylinder" then
			p.Size = Vector3.new(size.Y, size.X, size.Z)
			p.CFrame = CFrame.new(spec.offset) * CFrame.Angles(0, 0, math.pi / 2)
		else
			p.Size = size
			p.CFrame = CFrame.new(spec.offset)
		end
		if spec.shape == "Ball" then
			-- squash balls into food-like blobs
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = p
			p.Shape = Enum.PartType.Block
		end
		p.Color = spec.color
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = plate
		weld.Part1 = p
		weld.Parent = p
	end
	return model
end

local function holdPlate(player: Player, meal: PendingMeal)
	local character = player.Character
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	if not hand or not hand:IsA("BasePart") then
		return
	end
	local plate = meal.plate or makePlate(meal.def)
	meal.plate = plate
	for _, p in plate:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end
	local offset = if hand.Name == "RightHand" then CFrame.new(-0.3, -0.15, -0.9) else CFrame.new(-0.3, -0.9, -0.9)
	plate:PivotTo(hand.CFrame * offset * CFrame.Angles(0, 0, math.pi / 2))
	local primary = plate.PrimaryPart :: BasePart
	local old = primary:FindFirstChild("HandWeld")
	if old then
		old:Destroy()
	end
	local weld = Instance.new("Weld")
	weld.Name = "HandWeld"
	weld.Part0 = hand
	weld.Part1 = primary
	weld.C0 = offset * CFrame.Angles(0, 0, math.pi / 2)
	weld.Parent = primary
	plate.Parent = character
end

local function clearMeal(player: Player)
	local meal = meals[player]
	meals[player] = nil
	if meal and meal.plate then
		meal.plate:Destroy()
	end
	if player.Parent then
		player:SetAttribute("MealPending", "")
	end
end

-- Leaving with an uneaten meal: it's eaten on the go (half the Well Fed time).
local function mealToGo(player: Player)
	local meal = meals[player]
	if not meal or meal.eating then
		return
	end
	clearMeal(player)
	if player.Parent then
		consume(player, meal.def, 0.5)
		Net.notify(player, "TO GO", "You ate your " .. meal.def.name .. " on the way out. Sit down next time for the full Well Fed buff.")
	end
end

local function eatAt(player: Player, seat: Seat)
	local meal = meals[player]
	local spot = seat:GetAttribute("PlateSpot")
	if not meal or meal.eating or typeof(spot) ~= "Vector3" then
		return
	end
	meal.eating = true
	local plate = meal.plate or makePlate(meal.def)
	meal.plate = plate
	local primary = plate.PrimaryPart :: BasePart
	local handWeld = primary:FindFirstChild("HandWeld")
	if handWeld then
		handWeld:Destroy()
	end
	plate.Parent = kitchenFolder
	for _, p in plate:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
		end
	end
	plate:PivotTo(CFrame.new(spot + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.pi / 2))
	Net.notify(player, "BON APPÉTIT", "Eating your " .. meal.def.name .. "...")

	local bites = 3
	for _ = 1, bites do
		task.wait(ShopsConfig.EAT_SECONDS / bites)
		local humanoid = humanoidOf(player)
		if meals[player] ~= meal or not humanoid or humanoid.SeatPart ~= seat then
			-- got up early: the rest of the meal goes back in their hand
			if meals[player] == meal then
				meal.eating = false
				holdPlate(player, meal)
			end
			return
		end
		for _, p in plate:GetChildren() do
			if p:IsA("BasePart") and p.Name == "Food" then
				TweenService:Create(p, TweenInfo.new(0.3), { Size = p.Size * 0.62 }):Play()
			end
		end
	end
	meals[player] = nil
	player:SetAttribute("MealPending", "")
	consume(player, meal.def, 1)
	local minutes = math.floor((meal.def.wellFed or 0) / 60)
	Net.notify(player, "WELL FED", string.format("Stamina restored. Well Fed for %d min.", minutes))
	task.delay(2, function()
		plate:Destroy()
	end)
end

---------------------------------------------------------------------------
-- State + actions
---------------------------------------------------------------------------
local function snapshot(player: Player)
	local w = wardrobe(player)
	if not w then
		return nil
	end
	local outfits = {}
	for i, outfit in w.outfits do
		outfits[i] = { name = outfit.name, saved = outfit.saved == true }
	end
	local meal = meals[player]
	return {
		owned = table.clone(w.owned),
		equipped = table.clone(w.equipped),
		colours = table.clone(w.colours),
		hair = w.hair,
		hairColor = w.hairColor,
		facial = w.facial,
		useRobloxAvatar = w.useRobloxAvatar,
		outfits = outfits,
		proteinReadyAt = (w.proteinAt or 0) + ShopsConfig.PROTEIN_COOLDOWN,
		mealPending = if meal then meal.def.id else "",
	}
end

local function isInteger(n: any, low: number, high: number): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= low and n <= high
end

local actions: { [string]: (Player, any, any, any, any) -> (boolean, string) } = {}

function actions.BuyItem(player, w, id)
	local item = type(id) == "string" and ITEMS[id]
	if not item then
		return false, "That item doesn't exist."
	end
	if not inShop(player, "Threads") then
		return false, "You can only buy clothes inside Threads Clothing."
	end
	if owns(w, item.id) then
		return false, "You already own the " .. item.name .. "."
	end
	if not charge(player, item.price, "Threads: " .. item.name) then
		return false, "Not enough cash."
	end
	table.insert(w.owned, item.id)
	PlayerData.markChanged(player)
	Net.notify(player, "PURCHASED", item.name .. " for " .. cash(item.price) .. ". It's in your Closet.")
	return true, "Bought " .. item.name .. ". Tap EQUIP to wear it."
end

function actions.Equip(player, w, id, variant)
	local item = type(id) == "string" and ITEMS[id]
	if not item then
		return false, "That item doesn't exist."
	end
	if not owns(w, item.id) then
		return false, "You don't own that yet."
	end
	if not isInteger(variant, 1, #item.variants) then
		return false, "Pick a colour."
	end
	if seatedElsewhere(player) then
		return false, "Get out of your seat or vehicle first."
	end
	w.equipped[item.slot] = item.id
	w.colours[item.slot] = variant
	w.useRobloxAvatar = false
	PlayerData.markChanged(player)
	refreshLook(player)
	return true, "Wearing " .. item.name .. " (" .. item.variants[variant].name .. ")."
end

function actions.Unequip(player, w, slot)
	if type(slot) ~= "string" or w.equipped[slot] == nil or not table.find(ShopsConfig.SLOTS, slot) then
		return false, "Nothing to take off."
	end
	if ShopsConfig.REQUIRED_SLOTS[slot] then
		return false, "Swap your " .. ShopsConfig.SLOT_LABELS[slot]:lower() .. " instead of taking them off."
	end
	if seatedElsewhere(player) then
		return false, "Get out of your seat or vehicle first."
	end
	w.equipped[slot] = ""
	w.useRobloxAvatar = false
	PlayerData.markChanged(player)
	refreshLook(player)
	return true, "Took off your " .. ShopsConfig.SLOT_LABELS[slot]:lower() .. "."
end

function actions.Barber(player, w, hair, colour, facial)
	if type(hair) ~= "string" or type(colour) ~= "string" or type(facial) ~= "string" then
		return false, "Pick a style."
	end
	local price = ShopsConfig.cutPrice(hair, colour, facial)
	if not price then
		return false, "The barber doesn't know that style."
	end
	local humanoid = humanoidOf(player)
	local seat = humanoid and humanoid.SeatPart
	if not inShop(player, "Barber") or not seat or not seat:GetAttribute("BarberChair") then
		return false, "Sit in a barber chair first."
	end
	if hair == w.hair and facial == w.facial and (colour == w.hairColor or (hair == "" or hair == "bald") and facial == "") and not w.useRobloxAvatar then
		return false, "That's already your look."
	end
	if not charge(player, price, "Fresh Cuts barber") then
		return false, "Not enough cash."
	end
	w.hair = hair
	w.hairColor = colour
	w.facial = facial
	w.useRobloxAvatar = false
	PlayerData.markChanged(player)
	refreshLook(player)
	Net.notify(player, "FRESH CUT", "Looking sharp. " .. cash(price) .. " paid.")
	return true, "Fresh cut! Looking sharp."
end

function actions.BuyFood(player, w, id)
	local food = type(id) == "string" and ShopsConfig.findOption(ShopsConfig.MART, id)
	if not food then
		return false, "Corner Mart doesn't sell that."
	end
	if not inShop(player, "Mart") then
		return false, "You need to be inside Corner Mart."
	end
	if food.strengthXP and os.time() < (w.proteinAt or 0) + ShopsConfig.PROTEIN_COOLDOWN then
		local wait = (w.proteinAt or 0) + ShopsConfig.PROTEIN_COOLDOWN - os.time()
		return false, string.format("Your body needs %d:%02d before another protein bar.", wait // 60, wait % 60)
	end
	if not charge(player, food.price, "Corner Mart: " .. food.name) then
		return false, "Not enough cash."
	end
	if food.strengthXP then
		w.proteinAt = os.time()
		PlayerData.markChanged(player)
	end
	consume(player, food, 1)
	Net.notify(player, food.name:upper(), food.desc)
	return true, "Enjoy your " .. food.name .. "."
end

function actions.OrderMeal(player, _w, id)
	local meal = type(id) == "string" and ShopsConfig.findOption(ShopsConfig.MEALS, id)
	if not meal then
		return false, "That's not on the menu."
	end
	if not inShop(player, "Kitchen") or Net.distance(player, kitchenCounter) > 18 then
		return false, "Order at the counter inside Mama's Kitchen."
	end
	if meals[player] then
		return false, "Finish the meal you're holding first."
	end
	if not charge(player, meal.price, "Mama's Kitchen: " .. meal.name) then
		return false, "Not enough cash."
	end
	local pending: PendingMeal = { def = meal, plate = nil, eating = false }
	meals[player] = pending
	player:SetAttribute("MealPending", meal.name)
	holdPlate(player, pending)
	Net.notify(player, "ORDER UP", meal.name .. " is ready. Sit at any table to eat.")
	local humanoid = humanoidOf(player)
	local seat = humanoid and humanoid.SeatPart
	if seat and seat:IsA("Seat") and seat:GetAttribute("KitchenSeat") then
		task.spawn(eatAt, player, seat)
	end
	return true, "Order up! Sit at a table to eat."
end

function actions.SaveOutfit(player, w, slot)
	if not isInteger(slot, 1, #w.outfits) then
		return false, "Pick an outfit slot."
	end
	local outfit = w.outfits[slot]
	outfit.saved = true
	outfit.equipped = table.clone(w.equipped)
	outfit.colours = table.clone(w.colours)
	PlayerData.markChanged(player)
	return true, "Saved your fit to " .. outfit.name .. "."
end

function actions.WearOutfit(player, w, slot)
	if not isInteger(slot, 1, #w.outfits) or not w.outfits[slot].saved then
		return false, "That outfit slot is empty."
	end
	if seatedElsewhere(player) then
		return false, "Get out of your seat or vehicle first."
	end
	local outfit = w.outfits[slot]
	for _, s in ShopsConfig.SLOTS do
		local id = outfit.equipped[s]
		local item = id and ITEMS[id]
		if id == "" and not ShopsConfig.REQUIRED_SLOTS[s] then
			w.equipped[s] = ""
		elseif item and item.slot == s and owns(w, id) then
			w.equipped[s] = id
			local variant = outfit.colours[s]
			w.colours[s] = if isInteger(variant, 1, #item.variants) then variant else 1
		end
	end
	w.useRobloxAvatar = false
	PlayerData.markChanged(player)
	refreshLook(player)
	return true, "Wearing " .. outfit.name .. "."
end

function actions.RenameOutfit(player, w, slot, name)
	if not isInteger(slot, 1, #w.outfits) or type(name) ~= "string" then
		return false, "Pick an outfit slot."
	end
	name = name:gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #name < 1 or utf8.len(name) == nil or (utf8.len(name) :: number) > 20 then
		return false, "Names are 1-20 characters."
	end
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(name, player.UserId, Enum.TextFilterContext.PrivateChat)
		return result:GetNonChatStringForUserAsync(player.UserId)
	end)
	if not ok or type(filtered) ~= "string" or filtered == "" then
		return false, "Couldn't check that name. Try again."
	end
	w.outfits[slot].name = filtered
	PlayerData.markChanged(player)
	return true, "Renamed to " .. filtered .. "."
end

function actions.SetAvatar(player, w, on)
	if type(on) ~= "boolean" then
		return false, "Invalid choice."
	end
	if seatedElsewhere(player) then
		return false, "Get out of your seat or vehicle first."
	end
	if w.useRobloxAvatar == on then
		return true, if on then "Already wearing your Roblox avatar." else "Already wearing your CITY GRIND look."
	end
	w.useRobloxAvatar = on
	PlayerData.markChanged(player)
	refreshLook(player)
	return true, if on then "Switched to your Roblox avatar." else "Switched to your CITY GRIND look."
end

ShopGetState.OnServerInvoke = function(player: Player)
	if not Net.allow(player, "ShopGetState", 0.2) then
		return nil
	end
	return snapshot(player)
end

ShopAction.OnServerInvoke = function(player: Player, action: any, a: any, b: any, c: any)
	if type(action) ~= "string" or not actions[action] then
		return { ok = false, msg = "Unknown action." }
	end
	if not Net.allow(player, "ShopAction", 0.3) then
		return { ok = false, msg = "Slow down a little.", state = snapshot(player) }
	end
	local w = wardrobe(player)
	if not w then
		return { ok = false, msg = "Your data is still loading." }
	end
	local ok, okResult, msg = pcall(actions[action], player, w, a, b, c)
	if not ok then
		warn("[CityGrind] Shops action failed:", action, okResult)
		return { ok = false, msg = "Something went wrong.", state = snapshot(player) }
	end
	return { ok = okResult, msg = msg, state = snapshot(player) }
end

---------------------------------------------------------------------------
-- World building helpers
---------------------------------------------------------------------------
type PartProps = {
	name: string?,
	size: Vector3,
	cf: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	reflectance: number?,
	collide: boolean?,
	shape: Enum.PartType?,
	parent: Instance,
}

local function part(p: PartProps): Part
	local b = Instance.new("Part")
	b.Name = p.name or "Part"
	b.Anchored = true
	local stretchedBall = p.shape == Enum.PartType.Ball and (p.size.X ~= p.size.Y or p.size.Y ~= p.size.Z)
	if p.shape and not stretchedBall then
		b.Shape = p.shape
	end
	b.Size = p.size
	if stretchedBall then
		-- Ball parts are always round; an ellipsoid needs a sphere mesh
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = b
	end
	b.CFrame = p.cf
	b.Color = p.color or Color3.fromRGB(160, 160, 160)
	b.Material = p.material or Enum.Material.SmoothPlastic
	b.Transparency = p.transparency or 0
	b.Reflectance = p.reflectance or 0
	b.CanCollide = if p.collide == nil then true else p.collide
	b.TopSurface = Enum.SurfaceType.Smooth
	b.BottomSurface = Enum.SurfaceType.Smooth
	b.Parent = p.parent
	return b
end

-- Upright cylinder (Part cylinders lie along X).
local function cylinder(parent: Instance, pos: Vector3, height: number, diameter: number, color: Color3, mat: Enum.Material?, collide: boolean?): Part
	return part({ name = "Cylinder", shape = Enum.PartType.Cylinder, size = Vector3.new(height, diameter, diameter), cf = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2), color = color, material = mat, collide = collide, parent = parent })
end

local function surfaceText(target: BasePart, face: Enum.NormalId, text: string, color: Color3, bg: Color3?, font: Enum.Font?): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bg or Color3.new(0, 0, 0)
	label.BackgroundTransparency = if bg then 0 else 1
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Font = font or Enum.Font.GothamBlack
	label.Parent = gui
	return gui
end

-- A board listing lines of "name ..... price" (price boards and menus).
local function listBoard(target: BasePart, face: Enum.NormalId, title: string, rows: { { string } }, fg: Color3, accent: Color3, bg: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = target
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = bg
	frame.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.04, 0)
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	local rowHeight = 0.84 / (#rows + 1.6)
	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.fromScale(1, rowHeight * 1.5)
	header.Text = title
	header.TextScaled = true
	header.Font = Enum.Font.GothamBlack
	header.TextColor3 = accent
	header.LayoutOrder = 0
	header.Parent = frame
	for i, row in rows do
		local line = Instance.new("Frame")
		line.BackgroundTransparency = 1
		line.Size = UDim2.fromScale(1, rowHeight)
		line.LayoutOrder = i
		line.Parent = frame
		for col = 1, 2 do
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(if col == 1 then 0.75 else 0.25, 0.8)
			label.Position = UDim2.fromScale(if col == 1 then 0 else 0.75, 0.1)
			label.Text = row[col] or ""
			label.TextScaled = true
			label.Font = if col == 1 then Enum.Font.GothamMedium else Enum.Font.GothamBold
			label.TextColor3 = if col == 1 then fg else accent
			label.TextXAlignment = if col == 1 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right
			label.Parent = line
		end
	end
end

local function prompt(parent: Instance, action: string, object: string, distance: number?, onTrigger: (Player) -> ()): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.MaxActivationDistance = distance or 8
	pp.RequiresLineOfSight = false
	pp.HoldDuration = 0
	pp.Parent = parent
	pp.Triggered:Connect(function(player)
		if Net.allow(player, "ShopPrompt", 0.4) and Net.alive(player) then
			onTrigger(player)
		end
	end)
	return pp
end

-- Invisible trigger volume to hang a prompt on.
local function promptSpot(parent: Instance, pos: Vector3, size: Vector3?): Part
	return part({ name = "PromptSpot", size = size or Vector3.new(2, 2, 2), cf = CFrame.new(pos), transparency = 1, collide = false, parent = parent })
end

local function openFor(key: string, mode: string, options: any?): (Player) -> ()
	return function(player: Player)
		if player:GetAttribute("Interior") == INTERIORS[key] then
			ShopOpen:FireClient(player, mode, options or {})
		end
	end
end

-- Seat with a "Sit" prompt (touch and gamepad friendly), hidden while occupied.
local function seatWithPrompt(seat: Seat, action: string, object: string)
	local pp = prompt(seat, action, object, 7, function(player)
		local humanoid = humanoidOf(player)
		if humanoid and not humanoid.SeatPart and seat.Occupant == nil and Net.distance(player, seat.Position) < 10 then
			seat:Sit(humanoid)
		end
	end)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		pp.Enabled = seat.Occupant == nil
	end)
end

local function plant(parent: Instance, pos: Vector3)
	cylinder(parent, pos + Vector3.new(0, 0.9, 0), 1.8, 1.8, Color3.fromRGB(150, 85, 55), Enum.Material.Concrete)
	for i, offset in { Vector3.new(0, 3, 0), Vector3.new(0.5, 2.4, 0.3), Vector3.new(-0.5, 2.6, -0.3) } do
		part({ name = "Leaves", shape = Enum.PartType.Ball, size = Vector3.one * (2.2 - i * 0.3), cf = CFrame.new(pos + offset), color = Color3.fromRGB(60, 140 + i * 10, 70), material = Enum.Material.Grass, collide = false, parent = parent })
	end
end

-- A wall mirror: framed, reflective glass (Roblox can't mirror players, so the
-- shop panels also switch to a mirror camera facing your character).
local function mirror(parent: Instance, cf: CFrame, w: number, h: number, frameColor: Color3): Part
	part({ name = "MirrorFrame", size = Vector3.new(w + 0.5, h + 0.5, 0.2), cf = cf * CFrame.new(0, 0, 0.12), color = frameColor, material = Enum.Material.Wood, parent = parent })
	return part({ name = "Mirror", size = Vector3.new(w, h, 0.1), cf = cf, color = Color3.fromRGB(205, 220, 230), material = Enum.Material.Glass, reflectance = 0.6, parent = parent })
end

local function mannequin(parent: Instance, base: CFrame, top: Color3, legs: Color3, shoes: Color3, extra: Color3?)
	local function at(x: number, y: number, z: number): CFrame
		return base * CFrame.new(x, y, z)
	end
	part({ name = "Pedestal", shape = Enum.PartType.Cylinder, size = Vector3.new(0.6, 3.2, 3.2), cf = at(0, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(240, 240, 240), material = Enum.Material.Marble, parent = parent })
	local skin = Color3.fromRGB(235, 235, 235)
	for _, side in { -0.5, 0.5 } do
		part({ size = Vector3.new(0.95, 2, 0.95), cf = at(side, 1.6, 0), color = legs, material = Enum.Material.Fabric, parent = parent })
		part({ size = Vector3.new(1, 0.4, 1.3), cf = at(side, 0.8, -0.1), color = shoes, material = Enum.Material.Fabric, parent = parent })
		part({ size = Vector3.new(0.9, 2, 0.9), cf = at(side * 3, 3.6, 0), color = top, material = Enum.Material.Fabric, parent = parent })
		part({ size = Vector3.new(0.85, 0.5, 0.85), cf = at(side * 3, 2.35, 0), color = skin, parent = parent })
	end
	part({ size = Vector3.new(2, 2, 1), cf = at(0, 3.6, 0), color = top, material = Enum.Material.Fabric, parent = parent })
	part({ name = "Head", shape = Enum.PartType.Ball, size = Vector3.one * 1.25, cf = at(0, 5.25, 0), color = skin, parent = parent })
	if extra then
		part({ name = "Cap", shape = Enum.PartType.Ball, size = Vector3.new(1.35, 0.9, 1.4), cf = at(0, 5.6, 0), color = extra, material = Enum.Material.Fabric, parent = parent })
	end
end

---------------------------------------------------------------------------
-- Threads Clothing interior
---------------------------------------------------------------------------
local function buildThreads(city: Instance, root: Instance)
	local O = Places.REGIONS.Threads
	local size = Vector3.new(64, 18, 48)
	local folder = Instance.new("Folder")
	folder.Name = "Threads"
	folder.Parent = root
	local function P(x: number, y: number, z: number): Vector3
		return O + Vector3.new(x, y, z)
	end
	Places.room("ThreadsRoom", O, size, { floorColor = Color3.fromRGB(228, 228, 230), floorMaterial = Enum.Material.Marble, wallColor = Color3.fromRGB(40, 40, 46), parent = folder })

	local door = Places.buildingDoor(city, "Threads Clothing")
	if door then
		Places.door({
			name = INTERIORS.Threads,
			door = door,
			inside = CFrame.lookAt(P(0, 0, -18), P(0, 0, 0)),
			exitAt = P(0, 0, -size.Z / 2 + 0.3),
			parent = folder,
		})
	end

	local pink = Color3.fromRGB(255, 120, 200)
	-- neon accent around the walls + big sign
	for _, z in { -size.Z / 2 + 0.05, size.Z / 2 - 0.05 } do
		part({ name = "Accent", size = Vector3.new(size.X, 0.25, 0.1), cf = CFrame.new(P(0, 12, z)), color = pink, material = Enum.Material.Neon, collide = false, parent = folder })
	end
	for _, x in { -size.X / 2 + 0.05, size.X / 2 - 0.05 } do
		part({ name = "Accent", size = Vector3.new(0.1, 0.25, size.Z), cf = CFrame.new(P(x, 12, 0)), color = pink, material = Enum.Material.Neon, collide = false, parent = folder })
	end
	local sign = part({ name = "Sign", size = Vector3.new(18, 3.5, 0.3), cf = CFrame.new(P(0, 14, size.Z / 2 - 0.2)), color = Color3.fromRGB(20, 20, 24), parent = folder })
	surfaceText(sign, Enum.NormalId.Front, "THREADS", pink)

	-- clothing racks, one per category (section 76)
	local spots = {
		Streetwear = Vector3.new(-20, 0, -4),
		Athletic = Vector3.new(0, 0, -4),
		Casual = Vector3.new(20, 0, -4),
		Luxury = Vector3.new(-20, 0, 9),
		Vintage = Vector3.new(0, 0, 9),
		Minimalist = Vector3.new(20, 0, 9),
	}
	for _, category in ShopsConfig.CATEGORIES do
		local c = P(spots[category].X, 0, spots[category].Z)
		local metal = if category == "Luxury" then Color3.fromRGB(215, 175, 70) else Color3.fromRGB(60, 60, 66)
		local metalMat = if category == "Luxury" then Enum.Material.Foil else Enum.Material.Metal
		for _, side in { -1, 1 } do
			part({ name = "Post", size = Vector3.new(0.3, 6.6, 0.3), cf = CFrame.new(c + Vector3.new(side * 4.2, 3.3, 0)), color = metal, material = metalMat, parent = folder })
			part({ name = "Foot", size = Vector3.new(0.3, 0.3, 2.6), cf = CFrame.new(c + Vector3.new(side * 4.2, 0.15, 0)), color = metal, material = metalMat, parent = folder })
		end
		part({ name = "Rail", shape = Enum.PartType.Cylinder, size = Vector3.new(8.7, 0.22, 0.22), cf = CFrame.new(c + Vector3.new(0, 6.4, 0)), color = metal, material = metalMat, parent = folder })
		local garments = {}
		for _, item in ShopsConfig.ITEM_LIST do
			if item.category == category and (item.slot == "top" or item.slot == "bottom") then
				for _, variant in item.variants do
					table.insert(garments, { item = item, color = variant.c1, trim = variant.c2 })
				end
			end
		end
		local count = math.min(#garments, 8)
		for i = 1, count do
			local g = garments[i]
			local x = -3.5 + (i - 1) * (7 / math.max(1, count - 1))
			local long = g.item.slot == "bottom"
			local h = if long then 3.2 else 2.6
			part({ name = "Hanger", size = Vector3.new(0.06, 0.4, 1.6), cf = CFrame.new(c + Vector3.new(x, 6.15, 0)), color = Color3.fromRGB(110, 80, 50), material = Enum.Material.Wood, collide = false, parent = folder })
			part({ name = "Garment", size = Vector3.new(0.22, h, if long then 1.2 else 2), cf = CFrame.new(c + Vector3.new(x, 5.95 - h / 2, 0)) * CFrame.Angles(0, math.rad((i % 3 - 1) * 4), 0), color = g.color, material = Enum.Material.Fabric, collide = false, parent = folder })
			if not long then
				part({ name = "Trim", size = Vector3.new(0.24, 0.2, 2.02), cf = CFrame.new(c + Vector3.new(x, 5.95 - h + 0.1, 0)), color = g.trim, material = Enum.Material.Fabric, collide = false, parent = folder })
			end
		end
		local board = part({ name = "CategorySign", size = Vector3.new(7, 1.2, 0.2), cf = CFrame.new(c + Vector3.new(0, 8.3, 0)), color = Color3.fromRGB(20, 20, 24), parent = folder })
		local accent = ShopsConfig.CATEGORY_COLORS[category]
		surfaceText(board, Enum.NormalId.Front, category:upper(), accent)
		surfaceText(board, Enum.NormalId.Back, category:upper(), accent)
		for _, side in { -1, 1 } do
			part({ name = "Cable", size = Vector3.new(0.05, size.Y - 8.9, 0.05), cf = CFrame.new(c + Vector3.new(side * 3, 8.9 + (size.Y - 8.9) / 2, 0)), color = Color3.fromRGB(30, 30, 30), collide = false, parent = folder })
		end
		local spot = promptSpot(folder, c + Vector3.new(0, 3, 0), Vector3.new(8, 6, 3))
		prompt(spot, "Browse", category .. " rack", 9, openFor("Threads", "Threads", { category = category }))
	end

	-- shoe wall (+x)
	local shoeX = size.X / 2 - 1.2
	for level = 0, 2 do
		local y = 1.6 + level * 2.6
		part({ name = "Shelf", size = Vector3.new(2.2, 0.2, 18), cf = CFrame.new(P(shoeX, y, 0)), color = Color3.fromRGB(235, 235, 235), parent = folder })
	end
	local shoeModels = {}
	for _, item in ShopsConfig.ITEM_LIST do
		if item.slot == "shoes" then
			for _, variant in item.variants do
				table.insert(shoeModels, variant)
			end
		end
	end
	for i, variant in shoeModels do
		local level = (i - 1) % 3
		local column = (i - 1) // 3
		local pos = P(shoeX, 1.7 + level * 2.6, -7.5 + column * 2.6)
		part({ name = "Sole", size = Vector3.new(1, 0.15, 1.7), cf = CFrame.new(pos + Vector3.new(0, 0.08, 0)), color = variant.c2, collide = false, parent = folder })
		part({ name = "Shoe", size = Vector3.new(0.9, 0.5, 1.3), cf = CFrame.new(pos + Vector3.new(0, 0.4, 0.15)), color = variant.c1, material = Enum.Material.Fabric, collide = false, parent = folder })
		part({ name = "Toe", shape = Enum.PartType.Ball, size = Vector3.new(0.9, 0.9, 0.9), cf = CFrame.new(pos + Vector3.new(0, 0.3, -0.45)), color = variant.c1, material = Enum.Material.Fabric, collide = false, parent = folder })
	end
	local shoeSign = part({ name = "ShoeSign", size = Vector3.new(8, 1.2, 0.2), cf = CFrame.new(P(shoeX + 0.9, 9.3, 0)) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(20, 20, 24), parent = folder })
	surfaceText(shoeSign, Enum.NormalId.Front, "SNEAKER WALL", pink)
	prompt(promptSpot(folder, P(shoeX - 2, 3, 0), Vector3.new(2, 6, 16)), "Browse", "Shoes", 9, openFor("Threads", "Threads", { group = "Shoes" }))

	-- accessories glass case (-x)
	local caseC = P(-28.5, 0, 0)
	part({ name = "CaseBase", size = Vector3.new(3, 3.2, 10), cf = CFrame.new(caseC + Vector3.new(0, 1.6, 0)), color = Color3.fromRGB(45, 35, 30), material = Enum.Material.Wood, parent = folder })
	part({ name = "CaseGlass", size = Vector3.new(3, 1.4, 10), cf = CFrame.new(caseC + Vector3.new(0, 3.9, 0)), color = Color3.fromRGB(200, 225, 235), material = Enum.Material.Glass, transparency = 0.7, parent = folder })
	part({ name = "CaseLight", size = Vector3.new(2.8, 0.1, 9.8), cf = CFrame.new(caseC + Vector3.new(0, 4.55, 0)), color = Color3.fromRGB(255, 250, 235), material = Enum.Material.Neon, collide = false, parent = folder })
	local display = { Color3.fromRGB(225, 180, 70), Color3.fromRGB(200, 40, 45), Color3.fromRGB(200, 205, 212), Color3.fromRGB(40, 80, 200), Color3.fromRGB(30, 30, 34) }
	for i, color in display do
		local pos = caseC + Vector3.new(0, 3.35, -4 + (i - 1) * 2)
		if i % 2 == 1 then
			-- a chain coiled on a stand
			cylinder(folder, pos, 0.08, 1.2, color, Enum.Material.Foil, false)
			part({ name = "Pendant", shape = Enum.PartType.Ball, size = Vector3.one * 0.35, cf = CFrame.new(pos + Vector3.new(0, 0.1, -0.5)), color = color, material = Enum.Material.Foil, collide = false, parent = folder })
		else
			-- a cap
			part({ name = "Cap", shape = Enum.PartType.Ball, size = Vector3.new(1.2, 0.9, 1.2), cf = CFrame.new(pos + Vector3.new(0, 0.1, 0)), color = color, material = Enum.Material.Fabric, collide = false, parent = folder })
			part({ name = "Brim", shape = Enum.PartType.Cylinder, size = Vector3.new(0.06, 1, 1), cf = CFrame.new(pos + Vector3.new(0.45, -0.05, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = color, material = Enum.Material.Fabric, collide = false, parent = folder })
		end
	end
	prompt(promptSpot(folder, caseC + Vector3.new(2, 3, 0), Vector3.new(2, 6, 10)), "Browse", "Accessories", 9, openFor("Threads", "Threads", { group = "Accessories" }))

	-- checkout counter by the entrance
	local counterC = P(-18, 0, -17)
	part({ name = "Counter", size = Vector3.new(12, 3.6, 3), cf = CFrame.new(counterC + Vector3.new(0, 1.8, 0)), color = Color3.fromRGB(25, 25, 28), material = Enum.Material.Wood, parent = folder })
	part({ name = "CounterTop", size = Vector3.new(12.4, 0.3, 3.4), cf = CFrame.new(counterC + Vector3.new(0, 3.75, 0)), color = Color3.fromRGB(240, 240, 240), material = Enum.Material.Marble, parent = folder })
	part({ name = "Register", size = Vector3.new(1.6, 1, 1.2), cf = CFrame.new(counterC + Vector3.new(3, 4.4, 0)), color = Color3.fromRGB(35, 35, 40), parent = folder })
	part({ name = "Screen", size = Vector3.new(1.4, 0.9, 0.1), cf = CFrame.new(counterC + Vector3.new(3, 5.2, 0.3)) * CFrame.Angles(math.rad(-15), 0, 0), color = pink, material = Enum.Material.Neon, parent = folder })
	prompt(promptSpot(folder, counterC + Vector3.new(0, 3, -2), Vector3.new(10, 4, 1)), "Shop all", "Threads", 9, openFor("Threads", "Threads", {}))

	-- mirrors on the back wall
	for _, x in { -10, 10 } do
		local m = mirror(folder, CFrame.new(P(x, 5.5, size.Z / 2 - 0.3)) * CFrame.Angles(0, math.pi, 0), 6, 9, Color3.fromRGB(25, 25, 28))
		prompt(m, "Check the mirror", "Closet", 9, openFor("Threads", "Closet", { mirror = true }))
	end

	-- changing booths (back-left corner)
	for i = 0, 2 do
		local bx = -29.3 + i * 4.3
		local bc = P(bx, 0, 20)
		for _, side in { -1, 1 } do
			part({ name = "BoothWall", size = Vector3.new(0.3, 9, 7.6), cf = CFrame.new(bc + Vector3.new(side * 2.1, 4.5, 0)), color = Color3.fromRGB(235, 235, 235), parent = folder })
		end
		part({ name = "CurtainRail", size = Vector3.new(4.2, 0.15, 0.15), cf = CFrame.new(bc + Vector3.new(0, 8.6, -3.7)), color = Color3.fromRGB(60, 60, 66), material = Enum.Material.Metal, parent = folder })
		local curtain = part({ name = "Curtain", size = Vector3.new(3.9, 8, 0.15), cf = CFrame.new(bc + Vector3.new(0, 4.5, -3.7)), color = Color3.fromRGB(130, 30, 70), material = Enum.Material.Fabric, collide = false, parent = folder })
		part({ name = "BoothBench", size = Vector3.new(3.4, 1.4, 1.2), cf = CFrame.new(bc + Vector3.new(0, 0.7, 3)), color = Color3.fromRGB(80, 60, 45), material = Enum.Material.Wood, parent = folder })
		mirror(folder, CFrame.new(bc + Vector3.new(0, 5, 3.55)) * CFrame.Angles(0, math.pi, 0), 2.4, 5, Color3.fromRGB(235, 235, 235))
		prompt(curtain, "Change", "Changing room", 7, openFor("Threads", "Closet", { mirror = true }))
	end

	-- mannequins and decor
	mannequin(folder, CFrame.new(P(14, 0, -17)) * CFrame.Angles(0, math.pi, 0), Color3.fromRGB(30, 30, 34), Color3.fromRGB(95, 100, 65), Color3.fromRGB(200, 40, 45), Color3.fromRGB(200, 40, 45))
	mannequin(folder, CFrame.new(P(22, 0, -17)) * CFrame.Angles(0, math.pi, 0), Color3.fromRGB(40, 80, 200), Color3.fromRGB(40, 80, 200), Color3.fromRGB(240, 240, 238), nil)
	part({ name = "Rug", size = Vector3.new(14, 0.05, 6), cf = CFrame.new(P(0, 0.03, 2.5)), color = Color3.fromRGB(70, 40, 60), material = Enum.Material.Fabric, collide = false, parent = folder })
	cylinder(folder, P(0, 0.9, 2.5), 1.8, 4, Color3.fromRGB(230, 220, 205), Enum.Material.Fabric)
	plant(folder, P(-29, 0, -21))
	plant(folder, P(29, 0, -21))
	plant(folder, P(29, 0, 21))
end

---------------------------------------------------------------------------
-- Fresh Cuts Barber interior
---------------------------------------------------------------------------
local function buildBarber(city: Instance, root: Instance)
	local O = Places.REGIONS.Barber
	local size = Vector3.new(40, 14, 32)
	local folder = Instance.new("Folder")
	folder.Name = "Barber"
	folder.Parent = root
	local function P(x: number, y: number, z: number): Vector3
		return O + Vector3.new(x, y, z)
	end
	Places.room("BarberRoom", O, size, { floorColor = Color3.fromRGB(240, 240, 240), floorMaterial = Enum.Material.SmoothPlastic, wallColor = Color3.fromRGB(228, 232, 240), parent = folder })

	local door = Places.buildingDoor(city, "Fresh Cuts Barber")
	if door then
		Places.door({
			name = INTERIORS.Barber,
			door = door,
			inside = CFrame.lookAt(P(0, 0, -10), P(0, 0, 0)),
			exitAt = P(0, 0, -size.Z / 2 + 0.3),
			parent = folder,
		})
	end

	-- checkered floor
	local tiles = Instance.new("Model")
	tiles.Name = "Tiles"
	tiles.Parent = folder
	for ix = 0, 9 do
		for iz = 0, 7 do
			local dark = (ix + iz) % 2 == 0
			part({ name = "Tile", size = Vector3.new(4, 0.05, 4), cf = CFrame.new(P(-18 + ix * 4, 0.025, -14 + iz * 4)), color = if dark then Color3.fromRGB(30, 30, 34) else Color3.fromRGB(240, 240, 240), material = Enum.Material.Marble, collide = false, parent = tiles })
		end
	end
	-- blue wainscot band
	local blue = Color3.fromRGB(60, 90, 160)
	for _, z in { -size.Z / 2 + 0.1, size.Z / 2 - 0.1 } do
		part({ name = "Wainscot", size = Vector3.new(size.X, 3.5, 0.2), cf = CFrame.new(P(0, 1.75, z)), color = blue, parent = folder })
	end
	for _, x in { -size.X / 2 + 0.1, size.X / 2 - 0.1 } do
		part({ name = "Wainscot", size = Vector3.new(0.2, 3.5, size.Z), cf = CFrame.new(P(x, 1.75, 0)), color = blue, parent = folder })
	end
	local sign = part({ name = "Sign", size = Vector3.new(14, 2.6, 0.3), cf = CFrame.new(P(0, 11.5, size.Z / 2 - 0.25)), color = Color3.fromRGB(20, 25, 40), parent = folder })
	surfaceText(sign, Enum.NormalId.Front, "FRESH CUTS", Color3.new(1, 1, 1))

	-- three stations: mirror, vanity, chair (seated players get the barber menu)
	for _, x in { -12, 0, 12 } do
		mirror(folder, CFrame.new(P(x, 6.6, size.Z / 2 - 0.25)) * CFrame.Angles(0, math.pi, 0), 5, 5.5, Color3.fromRGB(30, 30, 34))
		part({ name = "MirrorLight", size = Vector3.new(5.4, 0.3, 0.3), cf = CFrame.new(P(x, 9.8, size.Z / 2 - 0.4)), color = Color3.fromRGB(255, 250, 235), material = Enum.Material.Neon, collide = false, parent = folder })
		part({ name = "Vanity", size = Vector3.new(6, 3.3, 1.8), cf = CFrame.new(P(x, 1.65, size.Z / 2 - 1.1)), color = Color3.fromRGB(70, 50, 40), material = Enum.Material.Wood, parent = folder })
		part({ name = "VanityTop", size = Vector3.new(6.2, 0.25, 2), cf = CFrame.new(P(x, 3.42, size.Z / 2 - 1.1)), color = Color3.fromRGB(240, 240, 240), material = Enum.Material.Marble, parent = folder })
		for b, color in { Color3.fromRGB(60, 160, 220), Color3.fromRGB(240, 200, 60), Color3.fromRGB(220, 70, 70) } do
			cylinder(folder, P(x - 2 + b * 0.6, 4.0, size.Z / 2 - 1.2), 0.9, 0.35, color, Enum.Material.Glass, false)
		end
		part({ name = "Clippers", size = Vector3.new(0.3, 0.25, 0.9), cf = CFrame.new(P(x + 1.6, 3.67, size.Z / 2 - 1.2)), color = Color3.fromRGB(30, 30, 30), collide = false, parent = folder })

		local chairC = P(x, 0, 9.5)
		local chrome = Color3.fromRGB(200, 205, 212)
		local leather = Color3.fromRGB(150, 30, 35)
		cylinder(folder, chairC + Vector3.new(0, 0.15, 0), 0.3, 2.6, chrome, Enum.Material.Metal)
		cylinder(folder, chairC + Vector3.new(0, 0.9, 0), 1.3, 0.6, chrome, Enum.Material.Metal)
		local seat = Instance.new("Seat")
		seat.Name = "BarberSeat"
		seat.Anchored = true
		seat.Size = Vector3.new(2.4, 0.5, 2.2)
		seat.CFrame = CFrame.lookAt(chairC + Vector3.new(0, 1.8, 0), chairC + Vector3.new(0, 1.8, 5))
		seat.Color = leather
		seat.Material = ShopsConfig.material("Leather", Enum.Material.SmoothPlastic)
		seat.TopSurface = Enum.SurfaceType.Smooth
		seat:SetAttribute("BarberChair", true)
		seat.Parent = folder
		part({ name = "Back", size = Vector3.new(2.4, 2.6, 0.4), cf = seat.CFrame * CFrame.new(0, 1.5, 1.1), color = leather, material = seat.Material, parent = folder })
		part({ name = "Headrest", size = Vector3.new(1.2, 0.6, 0.35), cf = seat.CFrame * CFrame.new(0, 3.1, 1.1), color = leather, material = seat.Material, parent = folder })
		for _, side in { -1, 1 } do
			part({ name = "Armrest", size = Vector3.new(0.35, 0.3, 2), cf = seat.CFrame * CFrame.new(side * 1.35, 0.8, 0), color = chrome, material = Enum.Material.Metal, parent = folder })
		end
		part({ name = "Footrest", size = Vector3.new(2, 0.15, 0.8), cf = seat.CFrame * CFrame.new(0, -1.2, -1.6), color = chrome, material = Enum.Material.Metal, parent = folder })
		seatWithPrompt(seat, "Get a cut", "Barber chair")
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant
			local player = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
			if player and player:GetAttribute("Interior") == INTERIORS.Barber then
				ShopOpen:FireClient(player, "Barber", {})
			end
		end)
	end

	-- waiting area + price board (real prices from ShopsConfig)
	local benchX = -size.X / 2 + 1.4
	part({ name = "Bench", size = Vector3.new(2, 1.6, 10), cf = CFrame.new(P(benchX, 0.8, -2)), color = Color3.fromRGB(70, 50, 40), material = Enum.Material.Wood, parent = folder })
	part({ name = "BenchBack", size = Vector3.new(0.4, 2.4, 10), cf = CFrame.new(P(benchX - 0.9, 2.8, -2)), color = Color3.fromRGB(150, 30, 35), material = Enum.Material.Fabric, parent = folder })
	part({ name = "MagazineTable", size = Vector3.new(2, 1.4, 2), cf = CFrame.new(P(benchX + 2.5, 0.7, -9)), color = Color3.fromRGB(40, 40, 44), parent = folder })
	for i, color in { Color3.fromRGB(220, 60, 60), Color3.fromRGB(60, 120, 220) } do
		part({ name = "Magazine", size = Vector3.new(0.9, 0.06, 1.2), cf = CFrame.new(P(benchX + 2.3 + i * 0.2, 1.43 + i * 0.06, -9)) * CFrame.Angles(0, i * 0.4, 0), color = color, collide = false, parent = folder })
	end
	local rows = {}
	for _, style in ShopsConfig.HAIR_STYLES do
		if style.id ~= "" then
			table.insert(rows, { style.name, "$" .. style.price })
		end
	end
	for _, beard in ShopsConfig.FACIAL_HAIR do
		if beard.id ~= "" then
			table.insert(rows, { "+ " .. beard.name, "$" .. beard.price })
		end
	end
	table.insert(rows, { "+ Colour", "$0-50" })
	local board = part({ name = "PriceBoard", size = Vector3.new(8, 8, 0.2), cf = CFrame.new(P(-size.X / 2 + 0.25, 7.5, 8)) * CFrame.Angles(0, -math.pi / 2, 0), color = Color3.fromRGB(20, 20, 24), parent = folder })
	listBoard(board, Enum.NormalId.Front, "PRICES", rows, Color3.new(1, 1, 1), Color3.fromRGB(255, 200, 80), Color3.fromRGB(22, 24, 34))

	-- reception
	local rc = P(13, 0, -10.5)
	part({ name = "Reception", size = Vector3.new(7, 3.4, 2.5), cf = CFrame.new(rc + Vector3.new(0, 1.7, 0)), color = Color3.fromRGB(25, 30, 45), parent = folder })
	part({ name = "ReceptionTop", size = Vector3.new(7.3, 0.25, 2.8), cf = CFrame.new(rc + Vector3.new(0, 3.5, 0)), color = Color3.fromRGB(240, 240, 240), material = Enum.Material.Marble, parent = folder })
	part({ name = "Register", size = Vector3.new(1.4, 0.9, 1), cf = CFrame.new(rc + Vector3.new(1.8, 4.1, 0)), color = Color3.fromRGB(35, 35, 40), parent = folder })
	plant(folder, P(18, 0, -14))

	-- barber pole with stripes that crawl upward
	local poleBase = P(7, 2.2, -size.Z / 2 + 0.8)
	local stripeColors = { Color3.fromRGB(220, 40, 40), Color3.fromRGB(245, 245, 245), Color3.fromRGB(40, 70, 200), Color3.fromRGB(245, 245, 245) }
	local rings = {}
	for i = 1, 14 do
		rings[i] = cylinder(folder, poleBase + Vector3.new(0, (i - 1) * 0.36, 0), 0.36, 0.8, stripeColors[(i - 1) % 4 + 1], Enum.Material.Glass, false)
	end
	part({ name = "PoleCap", shape = Enum.PartType.Ball, size = Vector3.one * 1, cf = CFrame.new(poleBase + Vector3.new(0, 14 * 0.36 - 0.1, 0)), color = Color3.fromRGB(200, 205, 212), material = Enum.Material.Metal, collide = false, parent = folder })
	part({ name = "PoleCap", shape = Enum.PartType.Ball, size = Vector3.one * 1, cf = CFrame.new(poleBase + Vector3.new(0, -0.4, 0)), color = Color3.fromRGB(200, 205, 212), material = Enum.Material.Metal, collide = false, parent = folder })
	task.spawn(function()
		local shift = 0
		while folder.Parent do
			task.wait(0.35)
			shift += 1
			for i, ring in rings do
				ring.Color = stripeColors[(i - 1 - shift) % 4 + 1]
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Corner Mart interior
---------------------------------------------------------------------------
local function buildMart(city: Instance, root: Instance)
	local O = Places.REGIONS.CornerMart
	local size = Vector3.new(36, 14, 28)
	local folder = Instance.new("Folder")
	folder.Name = "CornerMart"
	folder.Parent = root
	local function P(x: number, y: number, z: number): Vector3
		return O + Vector3.new(x, y, z)
	end
	Places.room("MartRoom", O, size, { floorColor = Color3.fromRGB(235, 235, 230), floorMaterial = Enum.Material.SmoothPlastic, wallColor = Color3.fromRGB(240, 235, 220), parent = folder })

	local door = Places.buildingDoor(city, "Corner Mart")
	if door then
		Places.door({
			name = INTERIORS.Mart,
			door = door,
			inside = CFrame.lookAt(P(-4, 0, -9), P(-4, 0, 0)),
			exitAt = P(-4, 0, -size.Z / 2 + 0.3),
			parent = folder,
		})
	end
	local green = Color3.fromRGB(60, 200, 90)
	for _, z in { -size.Z / 2 + 0.1, size.Z / 2 - 0.1 } do
		part({ name = "Stripe", size = Vector3.new(size.X, 0.6, 0.2), cf = CFrame.new(P(0, 10.5, z)), color = green, parent = folder })
	end
	local sign = part({ name = "Sign", size = Vector3.new(14, 2, 0.3), cf = CFrame.new(P(0, 12, size.Z / 2 - 0.25)), color = Color3.fromRGB(20, 20, 24), parent = folder })
	surfaceText(sign, Enum.NormalId.Front, "CORNER MART", green)

	local function openMart(player: Player)
		if player:GetAttribute("Interior") == INTERIORS.Mart then
			ShopOpen:FireClient(player, "Mart", {})
		end
	end

	-- checkout counter
	local cc = P(10, 0, -8)
	part({ name = "Counter", size = Vector3.new(9, 3.4, 3), cf = CFrame.new(cc + Vector3.new(0, 1.7, 0)), color = green:Lerp(Color3.new(0, 0, 0), 0.3), parent = folder })
	part({ name = "CounterTop", size = Vector3.new(9.3, 0.25, 3.3), cf = CFrame.new(cc + Vector3.new(0, 3.5, 0)), color = Color3.fromRGB(230, 230, 230), material = Enum.Material.Marble, parent = folder })
	part({ name = "Register", size = Vector3.new(1.6, 1, 1.2), cf = CFrame.new(cc + Vector3.new(-2.5, 4.1, 0)), color = Color3.fromRGB(35, 35, 40), parent = folder })
	part({ name = "Screen", size = Vector3.new(1.3, 0.8, 0.1), cf = CFrame.new(cc + Vector3.new(-2.5, 4.9, -0.3)) * CFrame.Angles(math.rad(15), 0, 0), color = green, material = Enum.Material.Neon, parent = folder })
	local candyRng = Random.new(11)
	for i = 0, 5 do
		part({ name = "Candy", size = Vector3.new(0.5, 0.7, 0.3), cf = CFrame.new(cc + Vector3.new(1 + i * 0.55, 3.97, -1.1)), color = Color3.fromHSV(candyRng:NextNumber(), 0.8, 0.95), collide = false, parent = folder })
	end
	-- coffee + slushie machines on the back counter
	part({ name = "BackCounter", size = Vector3.new(8, 3.4, 2), cf = CFrame.new(P(14, 1.7, -2)), color = Color3.fromRGB(60, 60, 66), parent = folder })
	part({ name = "Slushie", size = Vector3.new(2, 2.4, 1.4), cf = CFrame.new(P(12, 4.6, -2)), color = Color3.fromRGB(240, 240, 240), parent = folder })
	for i, color in { Color3.fromRGB(220, 40, 60), Color3.fromRGB(40, 120, 230) } do
		part({ name = "SlushieTank", size = Vector3.new(0.8, 1.4, 1), cf = CFrame.new(P(11.5 + (i - 1), 5.1, -2.3)), color = color, material = Enum.Material.Glass, transparency = 0.2, parent = folder })
	end
	part({ name = "Coffee", size = Vector3.new(1.8, 2, 1.4), cf = CFrame.new(P(15.5, 4.4, -2)), color = Color3.fromRGB(30, 30, 34), material = Enum.Material.Metal, parent = folder })
	prompt(promptSpot(folder, cc + Vector3.new(0, 3, -2.2), Vector3.new(8, 4, 1)), "Checkout", "Corner Mart", 9, openMart)

	-- aisles of shelves with products
	local rng = Random.new(42)
	for _, x in { -14, -7.5, -1 } do
		local ac = P(x, 0, 3)
		part({ name = "ShelfUnit", size = Vector3.new(1.4, 6, 10), cf = CFrame.new(ac + Vector3.new(0, 3, 0)), color = Color3.fromRGB(210, 210, 215), material = Enum.Material.Metal, parent = folder })
		for level = 0, 2 do
			local y = 0.9 + level * 1.9
			for _, side in { -1, 1 } do
				part({ name = "Shelf", size = Vector3.new(1, 0.12, 10), cf = CFrame.new(ac + Vector3.new(side * 1.2, y, 0)), color = Color3.fromRGB(235, 235, 240), parent = folder })
				local z = -4.6
				while z < 4.4 do
					local w = rng:NextNumber(0.6, 1.2)
					local h = rng:NextNumber(0.7, 1.4)
					part({ name = "Product", size = Vector3.new(0.7, h, w), cf = CFrame.new(ac + Vector3.new(side * 1.2, y + 0.06 + h / 2, z + w / 2)), color = Color3.fromHSV(rng:NextNumber(), rng:NextNumber(0.5, 0.9), rng:NextNumber(0.6, 1)), collide = false, parent = folder })
					z += w + 0.12
				end
			end
		end
		prompt(promptSpot(folder, ac + Vector3.new(0, 3, -5.6), Vector3.new(3, 4, 1)), "Browse snacks", "Corner Mart", 8, openMart)
	end

	-- fridge wall with drinks
	local fridgeZ = size.Z / 2 - 1.4
	for i = 0, 3 do
		local fx = -12 + i * 6
		local fc = P(fx, 0, fridgeZ)
		part({ name = "Fridge", size = Vector3.new(5.6, 8.4, 2.6), cf = CFrame.new(fc + Vector3.new(0, 4.2, 0.2)), color = Color3.fromRGB(50, 52, 58), material = Enum.Material.Metal, parent = folder })
		local inside = part({ name = "FridgeInside", size = Vector3.new(5, 7.4, 0.1), cf = CFrame.new(fc + Vector3.new(0, 4.3, -0.9)), color = Color3.fromRGB(235, 245, 255), material = Enum.Material.SmoothPlastic, parent = folder })
		local light = Instance.new("SurfaceLight")
		light.Face = Enum.NormalId.Front
		light.Range = 8
		light.Brightness = 1.2
		light.Color = Color3.fromRGB(220, 240, 255)
		light.Parent = inside
		for level = 0, 3 do
			local y = 1.3 + level * 1.8
			part({ name = "FridgeShelf", size = Vector3.new(5, 0.1, 1.2), cf = CFrame.new(fc + Vector3.new(0, y, -1.5)), color = Color3.fromRGB(200, 210, 220), material = Enum.Material.Glass, transparency = 0.3, parent = folder })
			local hue = (i * 4 + level) / 16
			for b = 0, 6 do
				cylinder(folder, fc + Vector3.new(-2.1 + b * 0.7, y + 0.6, -1.5), 1.1, 0.42, Color3.fromHSV(hue, 0.75, 0.95), Enum.Material.SmoothPlastic, false)
			end
		end
		part({ name = "FridgeDoor", size = Vector3.new(5.4, 8, 0.15), cf = CFrame.new(fc + Vector3.new(0, 4.3, -2.25)), color = Color3.fromRGB(200, 225, 240), material = Enum.Material.Glass, transparency = 0.65, parent = folder })
		part({ name = "Handle", size = Vector3.new(0.15, 3, 0.2), cf = CFrame.new(fc + Vector3.new(2.3, 4.3, -2.45)), color = Color3.fromRGB(200, 205, 212), material = Enum.Material.Metal, parent = folder })
	end
	prompt(promptSpot(folder, P(-3, 3, fridgeZ - 3.5), Vector3.new(22, 4, 1)), "Grab a drink", "Fridge", 9, openMart)
	plant(folder, P(16, 0, 12))
end

---------------------------------------------------------------------------
-- Mama's Kitchen interior (the outside counter belongs to Jobs deliveries)
---------------------------------------------------------------------------
local function buildKitchen(city: Instance, root: Instance)
	local O = Places.REGIONS.Kitchen
	local size = Vector3.new(44, 14, 34)
	local folder = Instance.new("Folder")
	folder.Name = "MamasKitchen"
	folder.Parent = root
	kitchenFolder = folder
	local function P(x: number, y: number, z: number): Vector3
		return O + Vector3.new(x, y, z)
	end
	Places.room("KitchenRoom", O, size, { floorColor = Color3.fromRGB(150, 100, 65), floorMaterial = Enum.Material.WoodPlanks, wallColor = Color3.fromRGB(245, 225, 190), parent = folder })

	local door = Places.buildingDoor(city, "Mama's Kitchen")
	if door then
		Places.door({
			name = INTERIORS.Kitchen,
			door = door,
			inside = CFrame.lookAt(P(0, 0, -12), P(0, 0, 0)),
			exitAt = P(0, 0, -size.Z / 2 + 0.3),
			parent = folder,
		})
	end
	local brick = Color3.fromRGB(150, 60, 45)
	for _, z in { -size.Z / 2 + 0.1, size.Z / 2 - 0.1 } do
		part({ name = "Wainscot", size = Vector3.new(size.X, 3.4, 0.2), cf = CFrame.new(P(0, 1.7, z)), color = brick, material = Enum.Material.Brick, parent = folder })
	end
	for _, x in { -size.X / 2 + 0.1, size.X / 2 - 0.1 } do
		part({ name = "Wainscot", size = Vector3.new(0.2, 3.4, size.Z), cf = CFrame.new(P(x, 1.7, 0)), color = brick, material = Enum.Material.Brick, parent = folder })
	end

	-- order counter
	local cc = P(0, 0, 6.5)
	kitchenCounter = cc + Vector3.new(0, 3, 0)
	part({ name = "Counter", size = Vector3.new(24, 3.6, 2.5), cf = CFrame.new(cc + Vector3.new(0, 1.8, 0)), color = Color3.fromRGB(120, 45, 35), material = Enum.Material.Wood, parent = folder })
	part({ name = "CounterTop", size = Vector3.new(24.4, 0.3, 2.9), cf = CFrame.new(cc + Vector3.new(0, 3.75, 0)), color = Color3.fromRGB(240, 235, 225), material = Enum.Material.Marble, parent = folder })
	part({ name = "Register", size = Vector3.new(1.6, 1, 1.2), cf = CFrame.new(cc + Vector3.new(-8, 4.4, 0)), color = Color3.fromRGB(35, 35, 40), parent = folder })
	part({ name = "PieStand", shape = Enum.PartType.Ball, size = Vector3.new(2, 1.4, 2), cf = CFrame.new(cc + Vector3.new(7, 4.4, 0)), color = Color3.fromRGB(210, 230, 240), material = Enum.Material.Glass, transparency = 0.5, collide = false, parent = folder })
	cylinder(folder, cc + Vector3.new(7, 4.1, 0), 0.4, 1.3, Color3.fromRGB(220, 160, 80), Enum.Material.SmoothPlastic, false)
	local bell = part({ name = "Bell", shape = Enum.PartType.Ball, size = Vector3.new(0.6, 0.4, 0.6), cf = CFrame.new(cc + Vector3.new(-4, 4.1, -0.6)), color = Color3.fromRGB(225, 180, 70), material = Enum.Material.Foil, collide = false, parent = folder })
	prompt(bell, "Order food", "Mama's Kitchen", 10, function(player)
		if player:GetAttribute("Interior") == INTERIORS.Kitchen then
			ShopOpen:FireClient(player, "Kitchen", {})
		end
	end)

	-- menu board over the kitchen pass (real prices)
	local rows = {}
	for _, meal in ShopsConfig.MEALS do
		table.insert(rows, { meal.name, "$" .. meal.price })
	end
	local menu = part({ name = "Menu", size = Vector3.new(16, 6, 0.3), cf = CFrame.new(P(0, 9.6, size.Z / 2 - 0.3)), color = Color3.fromRGB(30, 25, 20), parent = folder })
	listBoard(menu, Enum.NormalId.Front, "MAMA'S MENU", rows, Color3.fromRGB(250, 240, 220), Color3.fromRGB(255, 200, 90), Color3.fromRGB(35, 30, 26))

	-- the kitchen behind the counter
	local steel = Color3.fromRGB(190, 195, 200)
	part({ name = "Stove", size = Vector3.new(5, 3.4, 2.6), cf = CFrame.new(P(-14, 1.7, 14.5)), color = Color3.fromRGB(40, 40, 44), material = Enum.Material.Metal, parent = folder })
	for _, off in { Vector3.new(-1.2, 0, -0.5), Vector3.new(1.2, 0, -0.5), Vector3.new(-1.2, 0, 0.6), Vector3.new(1.2, 0, 0.6) } do
		cylinder(folder, P(-14, 3.43, 14.5) + off, 0.06, 0.9, Color3.fromRGB(255, 110, 30), Enum.Material.Neon, false)
	end
	cylinder(folder, P(-15.2, 4.1, 14), 1.3, 1.3, steel, Enum.Material.Metal, false)
	part({ name = "Hood", size = Vector3.new(6, 1.6, 3.2), cf = CFrame.new(P(-14, 8.6, 14.6)), color = steel, material = Enum.Material.Metal, parent = folder })
	part({ name = "Prep", size = Vector3.new(7, 3.4, 2.4), cf = CFrame.new(P(1, 1.7, 14.8)), color = steel, material = Enum.Material.Metal, parent = folder })
	part({ name = "Board", size = Vector3.new(2, 0.15, 1.3), cf = CFrame.new(P(0, 3.48, 14.6)), color = Color3.fromRGB(170, 120, 70), material = Enum.Material.Wood, collide = false, parent = folder })
	part({ name = "Fridge", size = Vector3.new(3.4, 8, 2.6), cf = CFrame.new(P(10, 4, 15)), color = steel, material = Enum.Material.Metal, parent = folder })
	local grillLight = Instance.new("PointLight")
	grillLight.Color = Color3.fromRGB(255, 150, 80)
	grillLight.Range = 10
	grillLight.Brightness = 0.8
	grillLight.Parent = part({ name = "GrillGlow", size = Vector3.new(0.5, 0.5, 0.5), cf = CFrame.new(P(-14, 4.5, 14.5)), transparency = 1, collide = false, parent = folder })

	-- dining tables (eat here for the full Well Fed buff)
	local tableSpots = { Vector3.new(-14, 0, -10), Vector3.new(-14, 0, -1.5), Vector3.new(14, 0, -10), Vector3.new(14, 0, -1.5) }
	for t, spot in tableSpots do
		local tc = P(spot.X, 0, spot.Z)
		cylinder(folder, tc + Vector3.new(0, 0.1, 0), 0.2, 2, Color3.fromRGB(40, 40, 44), Enum.Material.Metal)
		cylinder(folder, tc + Vector3.new(0, 1.55, 0), 2.9, 0.45, Color3.fromRGB(40, 40, 44), Enum.Material.Metal)
		local topY = 3.15
		cylinder(folder, tc + Vector3.new(0, topY, 0), 0.3, 4.6, Color3.fromRGB(240, 238, 230), Enum.Material.SmoothPlastic)
		cylinder(folder, tc + Vector3.new(0, topY + 0.17, 0), 0.04, 4.3, if t % 2 == 0 then Color3.fromRGB(200, 50, 50) else Color3.fromRGB(60, 120, 200), Enum.Material.Fabric, false)
		cylinder(folder, tc + Vector3.new(0, topY + 0.4, 0), 0.5, 0.25, Color3.fromRGB(240, 240, 240), Enum.Material.Glass, false)
		-- pendant lamp
		part({ name = "Cord", size = Vector3.new(0.06, size.Y - 9, 0.06), cf = CFrame.new(tc + Vector3.new(0, 9 + (size.Y - 9) / 2, 0)), color = Color3.fromRGB(30, 30, 30), collide = false, parent = folder })
		local shade = part({ name = "Shade", shape = Enum.PartType.Ball, size = Vector3.new(1.8, 1.1, 1.8), cf = CFrame.new(tc + Vector3.new(0, 9, 0)), color = Color3.fromRGB(200, 70, 50), collide = false, parent = folder })
		local lamp = Instance.new("PointLight")
		lamp.Range = 14
		lamp.Brightness = 1
		lamp.Color = Color3.fromRGB(255, 220, 170)
		lamp.Parent = shade
		for _, side in { -1, 1 } do
			local seatPos = tc + Vector3.new(side * 3.3, 1.8, 0)
			local seat = Instance.new("Seat")
			seat.Name = "KitchenSeat"
			seat.Anchored = true
			seat.Size = Vector3.new(2, 0.4, 2)
			seat.CFrame = CFrame.lookAt(seatPos, Vector3.new(tc.X, seatPos.Y, tc.Z))
			seat.Color = Color3.fromRGB(130, 40, 35)
			seat.Material = Enum.Material.Fabric
			seat.TopSurface = Enum.SurfaceType.Smooth
			seat:SetAttribute("KitchenSeat", true)
			seat:SetAttribute("PlateSpot", tc + Vector3.new(side * 1.1, topY + 0.15, 0))
			seat.Parent = folder
			part({ name = "ChairBack", size = Vector3.new(2, 2.4, 0.3), cf = seat.CFrame * CFrame.new(0, 1.3, 0.9), color = Color3.fromRGB(110, 70, 45), material = Enum.Material.Wood, parent = folder })
			for _, lx in { -0.8, 0.8 } do
				for _, lz in { -0.8, 0.8 } do
					part({ name = "Leg", size = Vector3.new(0.2, 1.6, 0.2), cf = seat.CFrame * CFrame.new(lx, -1, lz), color = Color3.fromRGB(110, 70, 45), material = Enum.Material.Wood, parent = folder })
				end
			end
			seatWithPrompt(seat, "Sit", "Table")
			seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				local occupant = seat.Occupant
				local player = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
				if player and meals[player] then
					task.spawn(eatAt, player, seat)
				end
			end)
		end
	end
	plant(folder, P(-20, 0, -15))
	plant(folder, P(20, 0, -15))
	-- framed photos on the side walls
	for i, color in { Color3.fromRGB(200, 160, 90), Color3.fromRGB(120, 160, 200), Color3.fromRGB(200, 120, 120) } do
		part({ name = "Photo", size = Vector3.new(0.15, 2.4, 3), cf = CFrame.new(P(-size.X / 2 + 0.15, 6.5, -12 + i * 5)), color = color, parent = folder })
		part({ name = "Photo", size = Vector3.new(0.15, 2.4, 3), cf = CFrame.new(P(size.X / 2 - 0.15, 6.5, -12 + i * 5)), color = color, parent = folder })
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Shops.start(city: Instance)
	local root = Instance.new("Folder")
	root.Name = "Shops"
	root.Parent = city

	for _, builder in { buildThreads, buildBarber, buildMart, buildKitchen } do
		local ok, err = pcall(builder, city, root)
		if not ok then
			warn("[CityGrind] Shops: building an interior failed:", err)
		end
	end

	local function onPlayer(player: Player)
		player:SetAttribute("MealPending", "")
		player:SetAttribute("StaminaBoostUntil", 0)
		player:SetAttribute("WellFedUntil", 0)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		player.CharacterRemoving:Connect(function()
			mealToGo(player)
		end)
		player:GetAttributeChangedSignal("Interior"):Connect(function()
			if meals[player] and player:GetAttribute("Interior") ~= INTERIORS.Kitchen then
				mealToGo(player)
			end
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		clearMeal(player)
		realDescriptions[player] = nil
		spawnDescriptions[player] = nil
		applying[player] = nil
		applyAgain[player] = nil
	end)
end

return Shops
