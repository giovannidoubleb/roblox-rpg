-- CITY GRIND: shop catalog and the procedural outfit builder
-- (sections 49, 74, 75, 76, 77, 110).
--
-- Lives in ReplicatedStorage.CityGrind.ShopsConfig so the server prices and
-- validates from exactly the table the client renders. Clients only ever send
-- item ids; every price is read from here on the server.
--
-- No catalog asset ids are used. Every cosmetic is procedural:
--   * clothing recolours the body parts and adds welded trim pieces
--     (hoods, cuffs, stripes, soles, printed jersey numbers...)
--   * accessories and barber hair are real Accessory instances made of Parts
--     with SpecialMesh Sphere / Cylinder shapes sized from the Head.
-- ShopsConfig.Look.build runs on the server (the look everyone sees) and on the
-- client (the local try-on preview), so a preview always matches the result.

local ShopsConfig = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Resolves an Enum.Material by name, falling back when an engine build lacks it.
local function material(name: string?, fallback: Enum.Material): Enum.Material
	if not name then
		return fallback
	end
	local ok, m = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and m then m else fallback
end
ShopsConfig.material = material

---------------------------------------------------------------------------
-- Places
---------------------------------------------------------------------------
-- Interior names (the Player attribute "Interior" while inside).
ShopsConfig.INTERIORS = {
	Threads = "Threads Clothing",
	Barber = "Fresh Cuts Barber",
	Mart = "Corner Mart",
	Kitchen = "Mama's Kitchen",
}

---------------------------------------------------------------------------
-- Clothing catalog (Threads Clothing)
---------------------------------------------------------------------------
ShopsConfig.SLOTS = { "top", "bottom", "shoes", "hat", "face", "neck", "ears", "wrist", "band", "back" }
ShopsConfig.SLOT_LABELS = {
	top = "Tops",
	bottom = "Bottoms",
	shoes = "Shoes",
	hat = "Headwear",
	face = "Eyewear",
	neck = "Chains",
	ears = "Earrings",
	wrist = "Watches",
	band = "Wristbands",
	back = "Bags",
}
-- Filter groups used by the shop UI.
ShopsConfig.SLOT_GROUP = {
	top = "Tops",
	bottom = "Bottoms",
	shoes = "Shoes",
	hat = "Accessories",
	face = "Accessories",
	neck = "Accessories",
	ears = "Accessories",
	wrist = "Accessories",
	band = "Accessories",
	back = "Accessories",
}
ShopsConfig.GROUPS = { "Tops", "Bottoms", "Shoes", "Accessories" }
-- Slots that can be swapped but never left empty.
ShopsConfig.REQUIRED_SLOTS = { bottom = true }
ShopsConfig.CATEGORIES = { "Streetwear", "Athletic", "Casual", "Luxury", "Vintage", "Minimalist" }
ShopsConfig.CATEGORY_COLORS = {
	Streetwear = rgb(255, 120, 60),
	Athletic = rgb(90, 170, 255),
	Casual = rgb(110, 210, 140),
	Luxury = rgb(235, 190, 80),
	Vintage = rgb(200, 120, 200),
	Minimalist = rgb(200, 200, 210),
}

-- Section 1: every new player owns and wears these "basic clothes".
ShopsConfig.STARTER = { top = "basic_tee", bottom = "basic_joggers", shoes = "basic_sneakers" }

export type Variant = { name: string, c1: Color3, c2: Color3 }
export type Item = {
	id: string,
	name: string,
	slot: string,
	kind: string,
	category: string,
	price: number,
	desc: string,
	variants: { Variant },
	material: string?, -- Enum.Material name for the main colour (default Fabric)
	text: string?, -- printed graphic text
	style: string?, -- sub-style (e.g. "aviator", "pom", "iced")
}

local function v(name: string, c1: Color3, c2: Color3?): Variant
	return { name = name, c1 = c1, c2 = c2 or c1 }
end

local WHITE = rgb(240, 240, 238)
local BLACK = rgb(30, 30, 34)
local GREY = rgb(150, 150, 156)
local NAVY = rgb(35, 45, 85)
local RED = rgb(200, 40, 45)
local ROYAL = rgb(40, 80, 200)
local GOLD = rgb(225, 180, 70)
local SILVER = rgb(200, 205, 212)
local DIAMOND = rgb(220, 240, 255)

local ITEM_LIST: { Item } = {
	-- Minimalist (the starter basics live here too)
	{ id = "basic_tee", name = "Plain Tee", slot = "top", kind = "tee", category = "Minimalist", price = 15, desc = "A clean cotton tee. The city starts here.", variants = { v("White", WHITE), v("Black", BLACK), v("Heather Grey", GREY), v("Navy", NAVY) } },
	{ id = "basic_joggers", name = "Everyday Joggers", slot = "bottom", kind = "joggers", category = "Minimalist", price = 25, desc = "Soft joggers with ribbed cuffs.", variants = { v("Grey", rgb(125, 125, 132), rgb(95, 95, 100)), v("Black", BLACK, rgb(20, 20, 22)), v("Navy", NAVY, rgb(25, 30, 60)) } },
	{ id = "basic_sneakers", name = "Clean Sneakers", slot = "shoes", kind = "sneakers", category = "Minimalist", price = 30, desc = "Plain low-tops that go with everything.", variants = { v("White", WHITE, rgb(250, 250, 250)), v("Black", BLACK, WHITE), v("Grey", GREY, WHITE) } },
	{ id = "min_longsleeve", name = "Essential Long Sleeve", slot = "top", kind = "longsleeve", category = "Minimalist", price = 35, desc = "Long sleeves, no logos, no noise.", variants = { v("Cream", rgb(235, 225, 205)), v("Charcoal", rgb(60, 62, 68)), v("Olive", rgb(100, 110, 70)) } },
	{ id = "min_chinos", name = "Slim Chinos", slot = "bottom", kind = "chinos", category = "Minimalist", price = 45, desc = "Tapered chinos for any day.", variants = { v("Khaki", rgb(190, 165, 120)), v("Black", BLACK), v("Stone", rgb(170, 165, 155)) } },
	{ id = "min_beanie", name = "Ribbed Beanie", slot = "hat", kind = "beanie", category = "Minimalist", price = 20, desc = "A snug ribbed knit.", variants = { v("Black", BLACK), v("Oatmeal", rgb(215, 200, 175)), v("Rust", rgb(170, 80, 45)) } },
	{ id = "min_studs", name = "Silver Studs", slot = "ears", kind = "studs", category = "Minimalist", price = 40, desc = "Small silver studs for both ears.", material = "Metal", variants = { v("Silver", SILVER) } },
	{ id = "min_watch", name = "Steel Watch", slot = "wrist", kind = "watch", category = "Minimalist", price = 120, desc = "Brushed steel with a leather strap.", material = "Metal", variants = { v("Black Dial", SILVER, rgb(25, 25, 28)), v("White Dial", SILVER, rgb(245, 245, 245)) } },

	-- Streetwear
	{ id = "st_hoodie", name = "Block Hoodie", slot = "top", kind = "hoodie", category = "Streetwear", price = 85, desc = "Heavyweight hoodie with a kangaroo pocket.", variants = { v("Black", BLACK, WHITE), v("Red", RED, WHITE), v("Forest", rgb(40, 85, 55), WHITE), v("Purple", rgb(95, 55, 150), WHITE) } },
	{ id = "st_graphic", name = "CITY GRIND Tee", slot = "top", kind = "graphictee", category = "Streetwear", price = 40, desc = "Rep the grind.", text = "CITY GRIND", variants = { v("White", WHITE, BLACK), v("Black", BLACK, rgb(255, 120, 60)), v("Sand", rgb(215, 195, 160), rgb(80, 50, 30)) } },
	{ id = "st_puffer", name = "Cloud Puffer", slot = "top", kind = "puffer", category = "Streetwear", price = 220, desc = "A quilted puffer jacket for cold nights.", material = "SmoothPlastic", variants = { v("Black", BLACK, rgb(200, 200, 200)), v("Orange", rgb(240, 120, 40), BLACK), v("Silver", rgb(195, 198, 205), BLACK) } },
	{ id = "st_cargo", name = "Utility Cargos", slot = "bottom", kind = "cargo", category = "Streetwear", price = 70, desc = "Loose cargos with side pockets.", variants = { v("Olive", rgb(95, 100, 65)), v("Black", BLACK), v("Sand", rgb(190, 170, 130)) } },
	{ id = "st_baggyjeans", name = "Baggy Jeans", slot = "bottom", kind = "jeans", category = "Streetwear", price = 65, desc = "Relaxed denim.", variants = { v("Light Wash", rgb(125, 160, 200)), v("Dark Wash", rgb(40, 55, 95)), v("Black Denim", rgb(40, 42, 48)) } },
	{ id = "st_hightops", name = "Court Hightops", slot = "shoes", kind = "hightops", category = "Streetwear", price = 140, desc = "Ankle-high court shoes.", variants = { v("Red / White", RED, WHITE), v("Black / White", BLACK, WHITE), v("Royal / White", ROYAL, WHITE) } },
	{ id = "st_cap", name = "Flat Brim Cap", slot = "hat", kind = "cap", category = "Streetwear", price = 35, desc = "Structured cap, flat brim.", variants = { v("Black", BLACK, BLACK), v("Red", RED, BLACK), v("Royal", ROYAL, WHITE) } },
	{ id = "st_bucket", name = "Bucket Hat", slot = "hat", kind = "bucket", category = "Streetwear", price = 30, desc = "Soft bucket hat.", variants = { v("Black", BLACK, rgb(60, 60, 60)), v("Tan", rgb(200, 175, 130), rgb(120, 95, 60)), v("Lilac", rgb(185, 160, 220), WHITE) } },
	{ id = "st_chain", name = "Cuban Link Chain", slot = "neck", kind = "chain", category = "Streetwear", price = 450, desc = "Heavy link chain with a medallion.", material = "Foil", variants = { v("Gold", GOLD, GOLD), v("Silver", SILVER, SILVER) } },
	{ id = "st_sling", name = "Sling Bag", slot = "back", kind = "sling", category = "Streetwear", price = 55, desc = "Worn across the chest.", variants = { v("Black", BLACK, rgb(60, 60, 66)), v("Camo Green", rgb(85, 95, 60), BLACK) } },

	-- Athletic
	{ id = "ath_jersey", name = "Neighborhood Jersey", slot = "top", kind = "jersey", category = "Athletic", price = 60, desc = "Your name and number on the back.", text = "23", variants = { v("Red / White", RED, WHITE), v("Royal / White", ROYAL, WHITE), v("Black / Gold", BLACK, GOLD), v("Green / White", rgb(30, 130, 70), WHITE) } },
	{ id = "ath_tank", name = "Training Tank", slot = "top", kind = "tank", category = "Athletic", price = 25, desc = "Sleeveless and breathable.", variants = { v("Black", BLACK), v("White", WHITE), v("Volt", rgb(210, 240, 40)) } },
	{ id = "ath_shorts", name = "Ball Shorts", slot = "bottom", kind = "ballshorts", category = "Athletic", price = 35, desc = "Long mesh shorts for the court.", variants = { v("Red / White", RED, WHITE), v("Black / White", BLACK, WHITE), v("Royal / White", ROYAL, WHITE) } },
	{ id = "ath_track", name = "Track Pants", slot = "bottom", kind = "trackpants", category = "Athletic", price = 55, desc = "Two side stripes, all business.", variants = { v("Black / White", BLACK, WHITE), v("Navy / White", NAVY, WHITE), v("Red / White", RED, WHITE) } },
	{ id = "ath_runners", name = "Runner Pro", slot = "shoes", kind = "runners", category = "Athletic", price = 90, desc = "Light runners with a bright accent.", variants = { v("Volt", rgb(210, 240, 40), BLACK), v("Grey / Orange", GREY, rgb(255, 120, 40)), v("White / Blue", WHITE, ROYAL) } },
	{ id = "ath_headband", name = "Sport Headband", slot = "hat", kind = "headband", category = "Athletic", price = 15, desc = "Keeps the sweat out of your eyes.", variants = { v("White", WHITE, RED), v("Black", BLACK, WHITE), v("Red", RED, WHITE) } },
	{ id = "ath_wristband", name = "Wristband", slot = "band", kind = "sweatband", category = "Athletic", price = 15, desc = "Terry wristband for your right arm.", variants = { v("White", WHITE, RED), v("Black", BLACK, WHITE), v("Red", RED, WHITE) } },
	{ id = "ath_backpack", name = "Gym Backpack", slot = "back", kind = "backpack", category = "Athletic", price = 60, desc = "Room for shoes, a ball and a towel.", variants = { v("Black", BLACK, rgb(70, 70, 76)), v("Red", RED, BLACK), v("Grey", GREY, BLACK) } },

	-- Casual
	{ id = "cas_polo", name = "Weekend Polo", slot = "top", kind = "polo", category = "Casual", price = 45, desc = "A collar for when it matters a little.", variants = { v("Navy", NAVY, WHITE), v("White", WHITE, NAVY), v("Forest", rgb(40, 90, 60), WHITE) } },
	{ id = "cas_striped", name = "Striped Tee", slot = "top", kind = "stripedtee", category = "Casual", price = 30, desc = "Bold stripes, relaxed fit.", variants = { v("White / Navy", WHITE, NAVY), v("Red / White", RED, WHITE), v("Mustard / Black", rgb(220, 170, 50), BLACK) } },
	{ id = "cas_shorts", name = "Chino Shorts", slot = "bottom", kind = "shorts", category = "Casual", price = 30, desc = "Above-the-knee chino shorts.", variants = { v("Khaki", rgb(190, 165, 120)), v("Navy", NAVY), v("Olive", rgb(100, 105, 70)) } },
	{ id = "cas_jeans", name = "Classic Jeans", slot = "bottom", kind = "jeans", category = "Casual", price = 55, desc = "Straight-leg denim.", variants = { v("Mid Wash", rgb(70, 100, 150)), v("Dark Wash", rgb(35, 48, 85)) } },
	{ id = "cas_slides", name = "Pool Slides", slot = "shoes", kind = "slides", category = "Casual", price = 20, desc = "Slip on, slip off.", variants = { v("Black", BLACK, rgb(50, 50, 55)), v("White", WHITE, rgb(220, 220, 220)), v("Red", RED, WHITE) } },
	{ id = "cas_glasses", name = "Round Glasses", slot = "face", kind = "glasses", category = "Casual", price = 50, desc = "Clear lenses, round frames.", variants = { v("Black", BLACK), v("Tortoise", rgb(110, 65, 35)), v("Gold", GOLD) } },
	{ id = "cas_backcap", name = "Backwards Cap", slot = "hat", kind = "backcap", category = "Casual", price = 30, desc = "Dad cap, worn backwards.", variants = { v("Navy", NAVY, NAVY), v("White", WHITE, WHITE), v("Green", rgb(40, 110, 60), rgb(40, 110, 60)) } },

	-- Luxury
	{ id = "lux_leather", name = "Leather Jacket", slot = "top", kind = "jacket", category = "Luxury", price = 1200, desc = "Real-feel leather over a crisp tee.", material = "Leather", variants = { v("Black", rgb(25, 25, 28), WHITE), v("Brown", rgb(95, 55, 35), BLACK) } },
	{ id = "lux_silk", name = "Silk Shirt", slot = "top", kind = "shirt", category = "Luxury", price = 600, desc = "Smooth silk with a sharp collar.", material = "SmoothPlastic", variants = { v("Champagne", rgb(235, 215, 170), GOLD), v("Burgundy", rgb(110, 25, 40), GOLD), v("Emerald", rgb(20, 105, 70), GOLD) } },
	{ id = "lux_trousers", name = "Tailored Trousers", slot = "bottom", kind = "chinos", category = "Luxury", price = 450, desc = "Pressed wool trousers.", variants = { v("Charcoal", rgb(55, 57, 62)), v("Black", BLACK), v("Cream", rgb(230, 220, 200)) } },
	{ id = "lux_boots", name = "Designer Boots", slot = "shoes", kind = "boots", category = "Luxury", price = 900, desc = "Polished leather boots.", material = "Leather", variants = { v("Black", rgb(25, 25, 28), rgb(45, 35, 30)), v("Tan", rgb(165, 110, 60), rgb(70, 45, 30)) } },
	{ id = "lux_shades", name = "Aviator Shades", slot = "face", kind = "sunglasses", style = "aviator", category = "Luxury", price = 350, desc = "Teardrop lenses in a thin metal frame.", variants = { v("Gold / Smoke", GOLD, rgb(30, 30, 35)), v("Silver / Blue", SILVER, rgb(40, 80, 140)) } },
	{ id = "lux_icechain", name = "Iced Out Chain", slot = "neck", kind = "chain", style = "iced", category = "Luxury", price = 2500, desc = "Every link set with stones. The top of the city.", material = "Glass", variants = { v("Platinum", DIAMOND, DIAMOND), v("Gold / Ice", GOLD, DIAMOND) } },
	{ id = "lux_diamond", name = "Diamond Studs", slot = "ears", kind = "studs", style = "iced", category = "Luxury", price = 800, desc = "Two stones that catch every light.", material = "Glass", variants = { v("Diamond", DIAMOND) } },
	{ id = "lux_goldwatch", name = "Gold Watch", slot = "wrist", kind = "watch", category = "Luxury", price = 1500, desc = "Solid gold, champagne dial.", material = "Foil", variants = { v("Gold", GOLD, rgb(240, 225, 180)), v("Rose Gold", rgb(220, 150, 130), rgb(245, 235, 225)) } },

	-- Vintage
	{ id = "vin_varsity", name = "Varsity Jacket", slot = "top", kind = "varsity", category = "Vintage", price = 180, desc = "Wool body, contrast sleeves, chenille letter.", text = "C", variants = { v("Maroon / Cream", rgb(110, 25, 35), rgb(235, 225, 200)), v("Navy / Gold", NAVY, GOLD), v("Green / White", rgb(30, 90, 50), WHITE) } },
	{ id = "vin_trackjacket", name = "Retro Track Jacket", slot = "top", kind = "trackjacket", category = "Vintage", price = 75, desc = "Zip-up with stripes down the sleeves.", variants = { v("Teal / White", rgb(30, 140, 150), WHITE), v("Purple / Yellow", rgb(90, 50, 140), rgb(250, 210, 60)), v("Black / Red", BLACK, RED) } },
	{ id = "vin_denim", name = "Washed Denim", slot = "bottom", kind = "jeans", category = "Vintage", price = 60, desc = "Faded like it's been around.", variants = { v("Faded Blue", rgb(150, 175, 205)), v("Stonewash", rgb(105, 130, 165)) } },
	{ id = "vin_canvas", name = "Canvas Classics", slot = "shoes", kind = "canvas", category = "Vintage", price = 45, desc = "Canvas low-tops with a rubber toe.", variants = { v("Red", RED, WHITE), v("Black", BLACK, WHITE), v("Cream", rgb(235, 225, 200), WHITE) } },
	{ id = "vin_shades", name = "Retro Round Shades", slot = "face", kind = "sunglasses", style = "round", category = "Vintage", price = 40, desc = "Little round tinted lenses.", variants = { v("Black", BLACK, rgb(25, 25, 30)), v("Tortoise", rgb(110, 65, 35), rgb(70, 50, 30)) } },
	{ id = "vin_beanie", name = "Pom Beanie", slot = "hat", kind = "beanie", style = "pom", category = "Vintage", price = 25, desc = "Chunky knit with a pom-pom.", variants = { v("Mustard", rgb(215, 165, 50), rgb(240, 235, 220)), v("Navy", NAVY, RED) } },
	{ id = "vin_rucksack", name = "Canvas Rucksack", slot = "back", kind = "backpack", category = "Vintage", price = 70, desc = "Waxed canvas with leather straps.", variants = { v("Tan", rgb(175, 145, 100), rgb(90, 55, 35)), v("Olive", rgb(95, 100, 65), rgb(90, 55, 35)) } },
}

ShopsConfig.ITEM_LIST = ITEM_LIST
ShopsConfig.ITEMS = {} :: { [string]: Item }
for _, item in ITEM_LIST do
	ShopsConfig.ITEMS[item.id] = item
end

---------------------------------------------------------------------------
-- Barber (section 75)
---------------------------------------------------------------------------
export type Option = { id: string, name: string, price: number, desc: string? }

-- id "" keeps the player's own avatar hair.
ShopsConfig.HAIR_STYLES = {
	{ id = "", name = "My Own Hair", price = 0, desc = "Keep your avatar's hair." },
	{ id = "bald", name = "Clean Shave", price = 25, desc = "Smooth all over." },
	{ id = "buzz", name = "Buzz Cut", price = 25, desc = "Even and short." },
	{ id = "fade", name = "Fade", price = 45, desc = "Short on top, faded to skin." },
	{ id = "waves", name = "360 Waves", price = 60, desc = "Brushed ridges all around." },
	{ id = "curlytop", name = "Curly Top", price = 80, desc = "Curls on top, tapered sides." },
	{ id = "afro", name = "Afro", price = 100, desc = "Big, round and proud." },
	{ id = "braids", name = "Cornrow Braids", price = 160, desc = "Neat rows front to back." },
	{ id = "dreads", name = "Dreads", price = 200, desc = "Long locs all around." },
} :: { Option }

ShopsConfig.HAIR_COLORS = {
	{ id = "black", name = "Black", price = 0, color = rgb(28, 24, 22) },
	{ id = "darkbrown", name = "Dark Brown", price = 0, color = rgb(60, 40, 28) },
	{ id = "brown", name = "Brown", price = 10, color = rgb(110, 72, 45) },
	{ id = "ginger", name = "Ginger", price = 30, color = rgb(185, 90, 40) },
	{ id = "blonde", name = "Blonde", price = 25, color = rgb(225, 190, 110) },
	{ id = "platinum", name = "Platinum", price = 40, color = rgb(235, 230, 220) },
	{ id = "blue", name = "Electric Blue", price = 50, color = rgb(40, 100, 230) },
	{ id = "pink", name = "Pink", price = 50, color = rgb(240, 110, 180) },
	{ id = "green", name = "Mint Green", price = 50, color = rgb(90, 210, 150) },
} :: { Option & { color: Color3 } }

ShopsConfig.FACIAL_HAIR = {
	{ id = "", name = "Clean", price = 0 },
	{ id = "moustache", name = "Moustache", price = 15 },
	{ id = "goatee", name = "Goatee", price = 20 },
	{ id = "beard", name = "Full Beard", price = 35 },
} :: { Option }

ShopsConfig.MIN_CUT_PRICE = 25

local function find(list: { any }, id: string): any
	for _, entry in list do
		if entry.id == id then
			return entry
		end
	end
	return nil
end
ShopsConfig.findOption = find

-- Price of a barber visit. The colour only costs money when it is actually
-- used (a barber style or facial hair). Every visit costs at least $25.
function ShopsConfig.cutPrice(hair: string, hairColor: string, facial: string): number?
	local style, colour, beard = find(ShopsConfig.HAIR_STYLES, hair), find(ShopsConfig.HAIR_COLORS, hairColor), find(ShopsConfig.FACIAL_HAIR, facial)
	if not style or not colour or not beard then
		return nil
	end
	local total = style.price + beard.price
	if (hair ~= "" and hair ~= "bald") or facial ~= "" then
		total += colour.price
	end
	return math.max(ShopsConfig.MIN_CUT_PRICE, total)
end

---------------------------------------------------------------------------
-- Corner Mart (section 49 "buy drinks") and Mama's Kitchen
---------------------------------------------------------------------------
-- Effects: refill = full stamina refill (StaminaRefill remote),
-- boost = seconds of StaminaBoostUntil, wellFed = seconds of WellFedUntil,
-- strengthXP = Strength stat XP (limited by PROTEIN_COOLDOWN).
export type Food = { id: string, name: string, icon: string, price: number, desc: string, refill: boolean?, boost: number?, wellFed: number?, strengthXP: number? }

ShopsConfig.MART = {
	{ id = "water", name = "Bottled Water", icon = "💧", price = 3, desc = "Restores all your stamina.", refill = true },
	{ id = "chips", name = "Hot Chips", icon = "🌶️", price = 4, desc = "Restores all stamina + 3 min Well Fed.", refill = true, wellFed = 180 },
	{ id = "energy", name = "Volt Energy Drink", icon = "⚡", price = 5, desc = "Restores all stamina + 20s Energized.", refill = true, boost = 20 },
	{ id = "sports", name = "Sports Drink", icon = "🥤", price = 8, desc = "Restores all stamina + 60s Hydrated.", refill = true, boost = 60 },
	{ id = "protein", name = "Protein Bar", icon = "🍫", price = 10, desc = "+15 Strength training XP and a stamina refill. One every 5 min.", refill = true, strengthXP = 15 },
} :: { Food }
ShopsConfig.PROTEIN_COOLDOWN = 300

export type FoodPiece = { shape: string, size: Vector3, offset: Vector3, color: Color3 }
export type Meal = Food & { pieces: { FoodPiece } }

ShopsConfig.MEALS = {
	{ id = "grilledcheese", name = "Grilled Cheese & Soup", icon = "🥪", price = 12, desc = "Full stamina + 5 min Well Fed.", refill = true, wellFed = 300, pieces = {
		{ shape = "Block", size = Vector3.new(0.7, 0.18, 0.7), offset = Vector3.new(-0.35, 0.14, 0), color = rgb(220, 165, 70) },
		{ shape = "Cylinder", size = Vector3.new(0.5, 0.25, 0.6), offset = Vector3.new(0.4, 0.16, 0), color = rgb(200, 60, 40) },
	} },
	{ id = "burger", name = "Smash Burger & Fries", icon = "🍔", price = 16, desc = "Full stamina + 8 min Well Fed.", refill = true, wellFed = 480, pieces = {
		{ shape = "Cylinder", size = Vector3.new(0.6, 0.16, 0.6), offset = Vector3.new(-0.3, 0.12, 0), color = rgb(215, 150, 70) },
		{ shape = "Cylinder", size = Vector3.new(0.62, 0.12, 0.62), offset = Vector3.new(-0.3, 0.25, 0), color = rgb(90, 50, 30) },
		{ shape = "Ball", size = Vector3.new(0.6, 0.25, 0.6), offset = Vector3.new(-0.3, 0.38, 0), color = rgb(220, 155, 70) },
		{ shape = "Block", size = Vector3.new(0.4, 0.2, 0.35), offset = Vector3.new(0.4, 0.14, 0), color = rgb(245, 205, 90) },
	} },
	{ id = "chicken", name = "Fried Chicken Plate", icon = "🍗", price = 20, desc = "Full stamina + 10 min Well Fed.", refill = true, wellFed = 600, pieces = {
		{ shape = "Ball", size = Vector3.new(0.45, 0.3, 0.35), offset = Vector3.new(-0.3, 0.17, -0.15), color = rgb(185, 115, 45) },
		{ shape = "Ball", size = Vector3.new(0.45, 0.3, 0.35), offset = Vector3.new(-0.2, 0.17, 0.2), color = rgb(170, 100, 40) },
		{ shape = "Ball", size = Vector3.new(0.5, 0.22, 0.45), offset = Vector3.new(0.35, 0.13, 0), color = rgb(240, 225, 120) },
	} },
	{ id = "jerk", name = "Jerk Chicken & Rice", icon = "🍛", price = 24, desc = "Full stamina + 12 min Well Fed.", refill = true, wellFed = 720, pieces = {
		{ shape = "Ball", size = Vector3.new(0.7, 0.25, 0.6), offset = Vector3.new(0.25, 0.14, 0), color = rgb(245, 240, 225) },
		{ shape = "Ball", size = Vector3.new(0.5, 0.25, 0.4), offset = Vector3.new(-0.3, 0.16, 0), color = rgb(120, 45, 25) },
		{ shape = "Ball", size = Vector3.new(0.25, 0.12, 0.25), offset = Vector3.new(-0.1, 0.12, 0.3), color = rgb(60, 150, 60) },
	} },
	{ id = "soul", name = "Soul Food Platter", icon = "🍽️", price = 32, desc = "Full stamina + 16 min Well Fed.", refill = true, wellFed = 960, pieces = {
		{ shape = "Ball", size = Vector3.new(0.45, 0.25, 0.4), offset = Vector3.new(-0.35, 0.15, -0.15), color = rgb(240, 180, 60) },
		{ shape = "Ball", size = Vector3.new(0.4, 0.2, 0.4), offset = Vector3.new(0.3, 0.13, -0.2), color = rgb(40, 100, 45) },
		{ shape = "Block", size = Vector3.new(0.4, 0.2, 0.3), offset = Vector3.new(0.05, 0.13, 0.3), color = rgb(225, 175, 80) },
		{ shape = "Ball", size = Vector3.new(0.4, 0.3, 0.35), offset = Vector3.new(-0.1, 0.17, 0.05), color = rgb(160, 95, 40) },
	} },
	{ id = "steak", name = "Steak Dinner", icon = "🥩", price = 40, desc = "Full stamina + 20 min Well Fed.", refill = true, wellFed = 1200, pieces = {
		{ shape = "Ball", size = Vector3.new(0.8, 0.2, 0.55), offset = Vector3.new(-0.15, 0.13, 0), color = rgb(110, 50, 35) },
		{ shape = "Ball", size = Vector3.new(0.35, 0.25, 0.35), offset = Vector3.new(0.45, 0.15, -0.15), color = rgb(235, 215, 160) },
		{ shape = "Ball", size = Vector3.new(0.3, 0.15, 0.3), offset = Vector3.new(0.4, 0.12, 0.25), color = rgb(50, 140, 50) },
	} },
} :: { Meal }

ShopsConfig.EAT_SECONDS = 6

---------------------------------------------------------------------------
-- Look builder (shared by server apply and client preview)
---------------------------------------------------------------------------
export type LookData = {
	equipped: { [string]: string },
	colours: { [string]: number },
	hair: string,
	hairColor: string,
	facial: string,
}

-- ctx.isServer: accessories go through Humanoid:AddAccessory; else welded locally.
-- ctx.folder: where trim pieces go. ctx.strip(character) removes/hides the
-- avatar's own clothing. ctx.hide(accessory) hides one of the avatar's own
-- accessories. ctx.setColor(part, color, material) paints a body part.
export type Ctx = {
	isServer: boolean,
	folder: Instance,
	playerName: string,
	strip: (Model) -> (),
	hide: (Accessory) -> (),
	setColor: (BasePart, Color3, Enum.Material) -> (),
}

local Look = {}
ShopsConfig.Look = Look

Look.R15_PARTS = { "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot" }
Look.R6_PARTS = { "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

-- R6 limbs are split into the same named segments as R15:
-- { part, centre Y as a fraction of the part height, height fraction }.
local R6_SEGMENTS = {
	UpperTorso = { "Torso", 0.1, 0.8 },
	LowerTorso = { "Torso", -0.4, 0.2 },
	LeftUpperArm = { "Left Arm", 0.25, 0.5 },
	LeftLowerArm = { "Left Arm", -0.165, 0.33 },
	LeftHand = { "Left Arm", -0.415, 0.17 },
	RightUpperArm = { "Right Arm", 0.25, 0.5 },
	RightLowerArm = { "Right Arm", -0.165, 0.33 },
	RightHand = { "Right Arm", -0.415, 0.17 },
	LeftUpperLeg = { "Left Leg", 0.25, 0.5 },
	LeftLowerLeg = { "Left Leg", -0.175, 0.35 },
	LeftFoot = { "Left Leg", -0.425, 0.15 },
	RightUpperLeg = { "Right Leg", 0.25, 0.5 },
	RightLowerLeg = { "Right Leg", -0.175, 0.35 },
	RightFoot = { "Right Leg", -0.425, 0.15 },
}
local R6_GROUPS = {
	Torso = { "UpperTorso", "LowerTorso" },
	["Left Arm"] = { "LeftUpperArm", "LeftLowerArm", "LeftHand" },
	["Right Arm"] = { "RightUpperArm", "RightLowerArm", "RightHand" },
	["Left Leg"] = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
	["Right Leg"] = { "RightUpperLeg", "RightLowerLeg", "RightFoot" },
}

local SLEEVES = {
	tee = "short",
	graphictee = "short",
	stripedtee = "short",
	polo = "short",
	tank = "none",
	jersey = "none",
	hoodie = "long",
	longsleeve = "long",
	shirt = "long",
	jacket = "long",
	varsity = "long",
	puffer = "long",
	trackjacket = "long",
}
local SHORT_BOTTOMS = { shorts = true, ballshorts = true }

local ACCESSORY_SLOT_BY_TYPE = {
	Hat = "hat",
	Hair = "hair",
	Face = "face",
	Neck = "neck",
	Back = "back",
	Waist = "back",
}
local ACCESSORY_SLOT_BY_ATTACHMENT = {
	HairAttachment = "hair",
	HatAttachment = "hat",
	FaceFrontAttachment = "face",
	FaceCenterAttachment = "face",
	NeckAttachment = "neck",
	BodyBackAttachment = "back",
	WaistBackAttachment = "back",
}

-- Which CITY GRIND slot an avatar's own accessory competes with (nil = none).
function Look.accessorySlot(accessory: Accessory): string?
	local byType = ACCESSORY_SLOT_BY_TYPE[accessory.AccessoryType.Name]
	if byType then
		return byType
	end
	local handle = accessory:FindFirstChild("Handle")
	if handle then
		for _, child in handle:GetChildren() do
			if child:IsA("Attachment") and ACCESSORY_SLOT_BY_ATTACHMENT[child.Name] then
				return ACCESSORY_SLOT_BY_ATTACHMENT[child.Name]
			end
		end
	end
	return nil
end

-- True for layered clothing (shirts/jackets/pants made with WrapLayer).
function Look.isLayeredClothing(accessory: Accessory): boolean
	return accessory:FindFirstChildWhichIsA("WrapLayer", true) ~= nil
end

-- The visible size of the head (classic heads are a Part with a Head mesh).
function Look.headSize(head: BasePart): Vector3
	local mesh = head:FindFirstChildOfClass("SpecialMesh")
	if mesh and mesh.MeshType == Enum.MeshType.Head then
		return Vector3.new(1.2, 1.2, 1.2) * (mesh.Scale / 1.25)
	elseif mesh then
		return Vector3.new(1.2, 1.2, 1.2)
	end
	if head:IsA("MeshPart") then
		return head.Size
	end
	return Vector3.new(1.2, 1.2, 1.2)
end

-- The item definition and variant worn in a slot, or nil.
function Look.worn(look: LookData, slot: string): (Item?, Variant?)
	local id = look.equipped[slot]
	local item = id and ShopsConfig.ITEMS[id]
	if not item or item.slot ~= slot then
		return nil, nil
	end
	local variant = item.variants[look.colours[slot] or 1] or item.variants[1]
	return item, variant
end

function Look.hairColor(id: string): Color3
	local entry = find(ShopsConfig.HAIR_COLORS, id)
	return if entry then entry.color else ShopsConfig.HAIR_COLORS[1].color
end

local function darker(c: Color3, amount: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), amount)
end
local function lighter(c: Color3, amount: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), amount)
end

type Spec = {
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	mesh: string?, -- "Sphere" | "Cylinder" (SpecialMesh, stretches with the part)
	shape: Enum.PartType?,
	transparency: number?,
	reflectance: number?,
}

local function newPart(spec: Spec): Part
	local p = Instance.new("Part")
	p.Name = "CGPiece"
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if spec.shape then
		p.Shape = spec.shape
	end
	p.Size = Vector3.new(math.max(spec.size.X, 0.02), math.max(spec.size.Y, 0.02), math.max(spec.size.Z, 0.02))
	p.Color = spec.color
	p.Material = spec.material or Enum.Material.SmoothPlastic
	p.Transparency = spec.transparency or 0
	p.Reflectance = spec.reflectance or 0
	if spec.mesh then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = if spec.mesh == "Cylinder" then Enum.MeshType.Cylinder else Enum.MeshType.Sphere
		mesh.Parent = p
	end
	return p
end

-- A vertical disc / cylinder (SpecialMesh Cylinder's axis is X, so turn it upright).
local function vdisc(pos: Vector3, height: number, width: number, depth: number, color: Color3, mat: Enum.Material?): Spec
	return { size = Vector3.new(height, width, depth), cf = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2), color = color, material = mat, mesh = "Cylinder" }
end
-- A disc facing forward (axis along Z).
local function fdisc(pos: Vector3, thickness: number, height: number, width: number, color: Color3, mat: Enum.Material?): Spec
	return { size = Vector3.new(thickness, height, width), cf = CFrame.new(pos) * CFrame.Angles(0, math.pi / 2, 0), color = color, material = mat, mesh = "Cylinder" }
end

-- Builds the full look on a character. Safe to call repeatedly; callers clear
-- the previous build first (server) or restore it (client preview).
function Look.build(character: Model, look: LookData, ctx: Ctx)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	if not humanoid or not head or not head:IsA("BasePart") then
		return
	end
	local r6 = humanoid.RigType == Enum.HumanoidRigType.R6
	local skin = head.Color
	local folder = ctx.folder
	local hs = Look.headSize(head)

	type Seg = { part: BasePart, cf: CFrame, size: Vector3 }
	local function seg(name: string): Seg?
		if name == "Head" then
			return { part = head, cf = CFrame.identity, size = hs }
		end
		if r6 then
			local d = R6_SEGMENTS[name]
			local p = d and character:FindFirstChild(d[1])
			if not p or not p:IsA("BasePart") then
				return nil
			end
			return { part = p, cf = CFrame.new(0, p.Size.Y * d[2], 0), size = Vector3.new(p.Size.X, p.Size.Y * d[3], p.Size.Z) }
		end
		local p = character:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return { part = p, cf = CFrame.identity, size = p.Size }
		end
		return nil
	end

	-- A trim piece welded to a body segment (offset is relative to the segment centre).
	local function piece(segName: string, spec: Spec): Part?
		local s = seg(segName)
		if not s then
			return nil
		end
		local p = newPart(spec)
		local c0 = s.cf * spec.cf
		p.CFrame = s.part.CFrame * c0
		local weld = Instance.new("Weld")
		weld.Part0 = s.part
		weld.Part1 = p
		weld.C0 = c0
		weld.Parent = p
		p.Parent = folder
		return p
	end
	local function box(segName: string, size: Vector3, offset: Vector3, color: Color3, mat: Enum.Material?): Part?
		return piece(segName, { size = size, cf = CFrame.new(offset), color = color, material = mat })
	end

	-- A real Accessory built from parts. specs[1] becomes the Handle.
	local function accessory(slot: string, accType: Enum.AccessoryType, attachName: string, segName: string, specs: { Spec })
		local s = seg(segName)
		if not s or #specs == 0 then
			return
		end
		local acc = Instance.new("Accessory")
		acc.Name = "CG_" .. slot
		acc.AccessoryType = accType
		acc:SetAttribute("CityGrind", true)
		acc:SetAttribute("CGSlot", slot)
		local o = s.cf * specs[1].cf -- handle offset from the body part
		local handle = newPart(specs[1])
		handle.Name = "Handle"
		handle.CFrame = s.part.CFrame * o
		handle.Parent = acc
		for i = 2, #specs do
			local spec = specs[i]
			local p = newPart(spec)
			local rel = s.cf * spec.cf
			p.CFrame = s.part.CFrame * rel
			local weld = Instance.new("Weld")
			weld.Part0 = handle
			weld.Part1 = p
			weld.C0 = o:Inverse() * rel
			weld.Parent = p
			p.Parent = acc
		end
		local charAttachment = s.part:FindFirstChild(attachName)
		if ctx.isServer and charAttachment and charAttachment:IsA("Attachment") then
			local attachment = Instance.new("Attachment")
			attachment.Name = attachName
			attachment.CFrame = o:Inverse() * charAttachment.CFrame
			attachment.Parent = handle
			humanoid:AddAccessory(acc)
		else
			local weld = Instance.new("Weld")
			weld.Part0 = s.part
			weld.Part1 = handle
			weld.C0 = o
			weld.Parent = handle
			acc.Parent = if ctx.isServer then character else folder
		end
	end

	-- Text printed flat on the front or back of a segment (jersey numbers, logos).
	local function printOn(segName: string, back: boolean, build: (Frame) -> ())
		local s = seg(segName)
		if not s then
			return
		end
		local offset = if back then CFrame.new(0, 0, s.size.Z / 2 + 0.035) * CFrame.Angles(0, math.pi, 0) else CFrame.new(0, 0, -s.size.Z / 2 - 0.035)
		local p = piece(segName, { size = Vector3.new(s.size.X * 0.9, s.size.Y * 0.9, 0.05), cf = offset, color = Color3.new(1, 1, 1), transparency = 1 })
		if not p then
			return
		end
		p.Name = "CGPrint"
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 60
		gui.LightInfluence = 1
		gui.Parent = p
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromScale(1, 1)
		frame.Parent = gui
		build(frame)
	end
	local function printLabel(parent: Frame, text: string, pos: UDim2, size: UDim2, color: Color3, stroke: Color3?)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = pos
		label.Size = size
		label.Text = text
		label.TextScaled = true
		label.Font = Enum.Font.GothamBlack
		label.TextColor3 = color
		label.TextStrokeColor3 = stroke or Color3.new(0, 0, 0)
		label.TextStrokeTransparency = if stroke then 0 else 1
		label.Parent = parent
	end

	-------------------------------------------------------------------------
	-- 1. Remove the avatar's own clothing and hide accessories we replace.
	-------------------------------------------------------------------------
	ctx.strip(character)
	local filled: { [string]: boolean } = {}
	for _, slot in ShopsConfig.SLOTS do
		if (look.equipped[slot] or "") ~= "" then
			filled[slot] = true
		end
	end
	if look.hair ~= "" then
		filled.hair = true
	end
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") and not child:GetAttribute("CityGrind") then
			local slot = Look.accessorySlot(child)
			if slot and filled[slot] then
				ctx.hide(child)
			end
		end
	end

	-------------------------------------------------------------------------
	-- 2. Body colours. paint[segment] = colour/material; unpainted = skin.
	-------------------------------------------------------------------------
	type Paint = { color: Color3, material: Enum.Material }
	local paint: { [string]: Paint } = {}
	local function cover(names: { string }, color: Color3, mat: Enum.Material)
		for _, name in names do
			paint[name] = { color = color, material = mat }
		end
	end

	local top, topV = Look.worn(look, "top")
	local bottom, bottomV = Look.worn(look, "bottom")
	local shoes, shoesV = Look.worn(look, "shoes")
	local FABRIC = Enum.Material.Fabric

	if top and topV then
		local m = material(top.material, FABRIC)
		cover({ "UpperTorso", "LowerTorso" }, topV.c1, m)
		local sleeves = SLEEVES[top.kind] or "short"
		local armColor = if top.kind == "varsity" then topV.c2 else topV.c1
		if sleeves ~= "none" then
			cover({ "LeftUpperArm", "RightUpperArm" }, armColor, m)
		end
		if sleeves == "long" then
			cover({ "LeftLowerArm", "RightLowerArm" }, armColor, m)
		end
	end
	if bottom and bottomV then
		local m = material(bottom.material, FABRIC)
		cover({ "LeftUpperLeg", "RightUpperLeg" }, bottomV.c1, m)
		if not SHORT_BOTTOMS[bottom.kind] then
			cover({ "LeftLowerLeg", "RightLowerLeg" }, bottomV.c1, m)
		end
		if not top then
			cover({ "LowerTorso" }, bottomV.c1, m)
		end
	end
	if shoes and shoesV and shoes.kind ~= "slides" then
		cover({ "LeftFoot", "RightFoot" }, shoesV.c1, material(shoes.material, FABRIC))
	end

	local SKIN_MAT = Enum.Material.Plastic
	if r6 then
		-- One R6 limb holds several segments: paint it whole when they all match,
		-- otherwise keep it skin and wrap the painted segments in overlay boxes.
		for partName, segments in R6_GROUPS do
			local part = character:FindFirstChild(partName)
			if part and part:IsA("BasePart") then
				local first = paint[segments[1]]
				local uniform = first ~= nil
				for _, name in segments do
					local p = paint[name]
					if not p or not first or p.color ~= first.color or p.material ~= first.material then
						uniform = false
					end
				end
				if uniform and first then
					ctx.setColor(part, first.color, first.material)
				else
					ctx.setColor(part, skin, SKIN_MAT)
					for _, name in segments do
						local p = paint[name]
						local s = seg(name)
						if p and s then
							box(name, s.size + Vector3.new(0.04, 0.01, 0.04), Vector3.zero, p.color, p.material)
						end
					end
				end
			end
		end
	else
		for _, name in Look.R15_PARTS do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				local p = paint[name]
				ctx.setColor(part, if p then p.color else skin, if p then p.material else SKIN_MAT)
			end
		end
	end

	-------------------------------------------------------------------------
	-- 3. Clothing trim
	-------------------------------------------------------------------------
	local ut = seg("UpperTorso")
	local lt = seg("LowerTorso")
	local ua = seg("LeftUpperArm")
	local la = seg("LeftLowerArm")
	local ul = seg("LeftUpperLeg")
	local ll = seg("LeftLowerLeg")
	local ft = seg("LeftFoot")

	local function collar(color: Color3, height: number, width: number, mat: Enum.Material?)
		if ut then
			piece("UpperTorso", vdisc(Vector3.new(0, ut.size.Y / 2 + height / 2 - 0.05, 0.02), height, ut.size.X * width, ut.size.Z * 0.9, color, mat))
		end
	end
	local function ring(segName: string, s: Seg?, y: number, height: number, grow: number, color: Color3, mat: Enum.Material?)
		if s then
			box(segName, Vector3.new(s.size.X + grow, height, s.size.Z + grow), Vector3.new(0, y, 0), color, mat)
		end
	end
	local function both(fn: (side: number, prefix: string) -> ())
		fn(-1, "Left")
		fn(1, "Right")
	end

	if top and topV and ut then
		local k, c1, c2 = top.kind, topV.c1, topV.c2
		local m = material(top.material, FABRIC)
		local X, Y, Z = ut.size.X, ut.size.Y, ut.size.Z
		local front = -Z / 2
		if k == "hoodie" then
			piece("UpperTorso", { size = Vector3.new(X * 0.62, Y * 0.34, Z * 0.75), cf = CFrame.new(0, Y * 0.44, Z * 0.3), color = darker(c1, 0.08), material = m, mesh = "Sphere" })
			box("UpperTorso", Vector3.new(X * 0.55, Y * 0.22, 0.05), Vector3.new(0, -Y * 0.3, front - 0.025), darker(c1, 0.12), m)
			for _, side in { -1, 1 } do
				box("UpperTorso", Vector3.new(0.05, Y * 0.3, 0.05), Vector3.new(side * X * 0.08, Y * 0.22, front - 0.03), c2, Enum.Material.SmoothPlastic)
			end
			both(function(_, prefix)
				ring(prefix .. "LowerArm", la, -(la and la.size.Y or 1) / 2 + 0.07, 0.14, 0.04, darker(c1, 0.15), m)
			end)
			ring("LowerTorso", lt, -(lt and lt.size.Y or 0.4) * 0.15, (lt and lt.size.Y or 0.4) * 0.7, 0.05, darker(c1, 0.15), m)
		elseif k == "jersey" then
			for _, side in { -1, 1 } do
				box("UpperTorso", Vector3.new(0.03, Y * 0.9, Z * 0.7), Vector3.new(side * (X / 2 + 0.015), -Y * 0.03, 0), c2, m)
			end
			collar(c2, 0.08, 0.42, m)
			local number = top.text or "23"
			local name = string.upper(ctx.playerName):sub(1, 12)
			printOn("UpperTorso", true, function(frame)
				printLabel(frame, name, UDim2.fromScale(0.1, 0.06), UDim2.fromScale(0.8, 0.18), c2)
				printLabel(frame, number, UDim2.fromScale(0.15, 0.26), UDim2.fromScale(0.7, 0.62), c2, darker(c1, 0.4))
			end)
			printOn("UpperTorso", false, function(frame)
				printLabel(frame, number, UDim2.fromScale(0.3, 0.18), UDim2.fromScale(0.4, 0.42), c2, darker(c1, 0.4))
			end)
		elseif k == "graphictee" then
			local text = top.text or "CITY GRIND"
			printOn("UpperTorso", false, function(frame)
				printLabel(frame, text, UDim2.fromScale(0.08, 0.2), UDim2.fromScale(0.84, 0.3), c2)
				printLabel(frame, "EST. NEIGHBORHOOD", UDim2.fromScale(0.2, 0.52), UDim2.fromScale(0.6, 0.1), c2)
			end)
		elseif k == "stripedtee" then
			for _, f in { 0.28, 0.02, -0.24 } do
				ring("UpperTorso", ut, Y * f, Y * 0.09, 0.03, c2, m)
			end
			both(function(_, prefix)
				ring(prefix .. "UpperArm", ua, -(ua and ua.size.Y or 1) * 0.15, (ua and ua.size.Y or 1) * 0.12, 0.03, c2, m)
			end)
		elseif k == "polo" then
			collar(darker(c1, 0.06), 0.13, 0.55, m)
			box("UpperTorso", Vector3.new(0.16, Y * 0.3, 0.03), Vector3.new(0, Y * 0.32, front - 0.015), c2, m)
			for i = 0, 1 do
				piece("UpperTorso", { size = Vector3.new(0.07, 0.07, 0.04), cf = CFrame.new(0, Y * (0.4 - i * 0.14), front - 0.04), color = WHITE, mesh = "Sphere" })
			end
			both(function(_, prefix)
				ring(prefix .. "UpperArm", ua, -(ua and ua.size.Y or 1) / 2 + 0.06, 0.1, 0.03, c2, m)
			end)
		elseif k == "shirt" then
			collar(c1, 0.14, 0.58, m)
			for i = 0, 3 do
				piece("UpperTorso", { size = Vector3.new(0.07, 0.07, 0.04), cf = CFrame.new(0, Y * (0.32 - i * 0.2), front - 0.02), color = c2, material = Enum.Material.Foil, mesh = "Sphere" })
			end
			both(function(_, prefix)
				ring(prefix .. "LowerArm", la, -(la and la.size.Y or 1) / 2 + 0.08, 0.16, 0.04, c1, m)
			end)
		elseif k == "longsleeve" then
			both(function(_, prefix)
				ring(prefix .. "LowerArm", la, -(la and la.size.Y or 1) / 2 + 0.07, 0.12, 0.03, darker(c2, 0.08), m)
			end)
		elseif k == "jacket" then
			box("UpperTorso", Vector3.new(X * 0.26, Y * 0.97, 0.03), Vector3.new(0, -Y * 0.01, front - 0.012), c2, FABRIC)
			for _, side in { -1, 1 } do
				piece("UpperTorso", { size = Vector3.new(X * 0.15, Y * 0.42, 0.04), cf = CFrame.new(side * X * 0.17, Y * 0.24, front - 0.025) * CFrame.Angles(0, 0, side * 0.3), color = darker(c1, 0.15), material = m })
				box("UpperTorso", Vector3.new(0.04, Y * 0.55, 0.035), Vector3.new(side * X * 0.14, -Y * 0.22, front - 0.02), SILVER, Enum.Material.Metal)
			end
			collar(darker(c1, 0.1), 0.16, 0.6, m)
			ring("LowerTorso", lt, 0, (lt and lt.size.Y or 0.4) * 0.8, 0.05, darker(c1, 0.1), m)
			both(function(_, prefix)
				ring(prefix .. "LowerArm", la, -(la and la.size.Y or 1) / 2 + 0.08, 0.14, 0.04, darker(c1, 0.1), m)
			end)
		elseif k == "varsity" then
			collar(c2, 0.14, 0.55, m)
			ring("LowerTorso", lt, 0, (lt and lt.size.Y or 0.4) * 0.8, 0.05, c1, m)
			ring("LowerTorso", lt, 0, 0.06, 0.06, c2, m)
			both(function(_, prefix)
				ring(prefix .. "LowerArm", la, -(la and la.size.Y or 1) / 2 + 0.09, 0.16, 0.04, c1, m)
				ring(prefix .. "LowerArm", la, -(la and la.size.Y or 1) / 2 + 0.09, 0.04, 0.05, c2, m)
			end)
			for i = 0, 3 do
				piece("UpperTorso", { size = Vector3.new(0.08, 0.08, 0.04), cf = CFrame.new(0, Y * (0.3 - i * 0.2), front - 0.02), color = c2, mesh = "Sphere" })
			end
			local letter = top.text or "C"
			printOn("UpperTorso", false, function(frame)
				printLabel(frame, letter, UDim2.fromScale(0.08, 0.1), UDim2.fromScale(0.3, 0.38), c2, darker(c1, 0.3))
			end)
		elseif k == "puffer" then
			box("UpperTorso", Vector3.new(X + 0.22, Y * 1.02, Z + 0.22), Vector3.zero, c1, m)
			for _, f in { 0.3, 0.04, -0.22 } do
				ring("UpperTorso", ut, Y * f, 0.05, 0.25, darker(c1, 0.25), m)
			end
			box("UpperTorso", Vector3.new(0.05, Y, 0.02), Vector3.new(0, 0, front - 0.12), c2, Enum.Material.Metal)
			collar(c1, 0.32, 0.64, m)
			ring("LowerTorso", lt, 0, (lt and lt.size.Y or 0.4), 0.22, c1, m)
			both(function(_, prefix)
				if ua then
					ring(prefix .. "UpperArm", ua, 0, ua.size.Y, 0.14, c1, m)
					ring(prefix .. "UpperArm", ua, -ua.size.Y * 0.1, 0.05, 0.16, darker(c1, 0.25), m)
				end
				if la then
					ring(prefix .. "LowerArm", la, la.size.Y * 0.08, la.size.Y * 0.84, 0.1, c1, m)
				end
			end)
		elseif k == "trackjacket" then
			collar(c1, 0.2, 0.58, m)
			box("UpperTorso", Vector3.new(0.05, Y, 0.02), Vector3.new(0, 0, front - 0.012), c2, Enum.Material.SmoothPlastic)
			both(function(side, prefix)
				for _, s in { { prefix .. "UpperArm", ua }, { prefix .. "LowerArm", la } } do
					local sg = s[2] :: Seg?
					if sg then
						box(s[1], Vector3.new(0.03, sg.size.Y, sg.size.Z * 0.12), Vector3.new(side * (sg.size.X / 2 + 0.015), 0, -sg.size.Z * 0.1), c2, m)
						box(s[1], Vector3.new(0.03, sg.size.Y, sg.size.Z * 0.12), Vector3.new(side * (sg.size.X / 2 + 0.015), 0, sg.size.Z * 0.1), c2, m)
					end
				end
			end)
		end
	end

	if bottom and bottomV and ul then
		local k, c1, c2 = bottom.kind, bottomV.c1, bottomV.c2
		local m = material(bottom.material, FABRIC)
		local function stripes(segName: string, s: Seg?, side: number, color: Color3, count: number)
			if not s then
				return
			end
			for i = 1, count do
				local z = if count == 1 then 0 else (i - 1.5) * s.size.Z * 0.18
				box(segName, Vector3.new(0.03, s.size.Y, s.size.Z * 0.1), Vector3.new(side * (s.size.X / 2 + 0.015), 0, z), color, m)
			end
		end
		both(function(side, prefix)
			local up, low = prefix .. "UpperLeg", prefix .. "LowerLeg"
			if k == "shorts" then
				ring(up, ul, -ul.size.Y / 2 + 0.06, 0.12, 0.04, darker(c1, 0.12), m)
			elseif k == "ballshorts" then
				ring(up, ul, 0, ul.size.Y, 0.06, c1, m)
				if ll then
					ring(low, ll, ll.size.Y * 0.4, ll.size.Y * 0.2, 0.06, c1, m)
					ring(low, ll, ll.size.Y * 0.31, 0.06, 0.07, c2, m)
				end
				stripes(up, ul, side, c2, 1)
			elseif k == "joggers" then
				if ll then
					ring(low, ll, -ll.size.Y / 2 + 0.1, 0.2, 0.06, c2, m)
				end
			elseif k == "trackpants" then
				stripes(up, ul, side, c2, 2)
				stripes(low, ll, side, c2, 2)
				if ll then
					ring(low, ll, -ll.size.Y / 2 + 0.06, 0.12, 0.04, darker(c1, 0.2), m)
				end
			elseif k == "jeans" then
				box(up, Vector3.new(ul.size.X * 0.5, ul.size.Y * 0.28, 0.03), Vector3.new(0, ul.size.Y * 0.28, ul.size.Z / 2 + 0.015), darker(c1, 0.12), m)
				box(up, Vector3.new(0.02, ul.size.Y, 0.04), Vector3.new(side * (ul.size.X / 2 + 0.01), 0, 0), lighter(c1, 0.25), m)
				if ll then
					box(low, Vector3.new(0.02, ll.size.Y, 0.04), Vector3.new(side * (ll.size.X / 2 + 0.01), 0, 0), lighter(c1, 0.25), m)
					ring(low, ll, -ll.size.Y / 2 + 0.07, 0.14, 0.05, lighter(c1, 0.1), m)
				end
			elseif k == "cargo" then
				box(up, Vector3.new(0.07, ul.size.Y * 0.42, ul.size.Z * 0.62), Vector3.new(side * (ul.size.X / 2 + 0.035), -ul.size.Y * 0.12, 0), darker(c1, 0.08), m)
				box(up, Vector3.new(0.09, 0.08, ul.size.Z * 0.66), Vector3.new(side * (ul.size.X / 2 + 0.045), ul.size.Y * 0.1, 0), darker(c1, 0.22), m)
				if ll then
					ring(low, ll, -ll.size.Y / 2 + 0.08, 0.16, 0.06, darker(c1, 0.1), m)
				end
			elseif k == "chinos" then
				if ll then
					box(low, Vector3.new(0.02, ll.size.Y, 0.02), Vector3.new(0, 0, -ll.size.Z / 2 - 0.01), darker(c1, 0.15), m)
				end
			end
		end)
	end

	if shoes and shoesV and ft then
		local k, c1, c2 = shoes.kind, shoesV.c1, shoesV.c2
		local m = material(shoes.material, FABRIC)
		local fs = ft.size
		both(function(side, prefix)
			local footName, lowName = prefix .. "Foot", prefix .. "LowerLeg"
			-- sole + rounded toe for everything; then per-style details
			box(footName, Vector3.new(fs.X + 0.06, 0.14, fs.Z + 0.2), Vector3.new(0, -fs.Y / 2 + 0.02, -0.06), c2, Enum.Material.SmoothPlastic)
			if k == "slides" then
				box(footName, Vector3.new(fs.X + 0.07, fs.Y * 0.55, fs.Z * 0.45), Vector3.new(0, 0.02, -fs.Z * 0.12), c1, m)
				return
			end
			piece(footName, { size = Vector3.new(fs.X + 0.02, fs.Y * 0.95, 0.5), cf = CFrame.new(0, -fs.Y * 0.05, -fs.Z / 2), color = if k == "canvas" then c2 else c1, material = m, mesh = "Sphere" })
			box(footName, Vector3.new(fs.X * 0.4, 0.04, fs.Z * 0.5), Vector3.new(0, fs.Y / 2 + 0.01, -fs.Z * 0.12), if k == "boots" then darker(c1, 0.3) else lighter(c2, 0.3), m)
			if k == "hightops" and ll then
				ring(lowName, ll, -ll.size.Y / 2 + ll.size.Y * 0.16, ll.size.Y * 0.32, 0.08, c1, m)
				ring(lowName, ll, -ll.size.Y / 2 + ll.size.Y * 0.32, 0.05, 0.09, c2, m)
			elseif k == "boots" and ll then
				ring(lowName, ll, -ll.size.Y / 2 + ll.size.Y * 0.25, ll.size.Y * 0.5, 0.1, c1, m)
			elseif k == "runners" then
				box(footName, Vector3.new(0.03, fs.Y * 0.5, fs.Z * 0.6), Vector3.new(side * (fs.X / 2 + 0.015), 0, 0), c2, m)
			elseif k == "sneakers" or k == "canvas" then
				box(footName, Vector3.new(fs.X + 0.03, 0.05, fs.Z + 0.03), Vector3.new(0, -fs.Y / 2 + 0.11, 0), c2, m)
			end
		end)
	end

	-------------------------------------------------------------------------
	-- 4. Accessories (real Accessory instances)
	-------------------------------------------------------------------------
	-- Head geometry is in "head units": x/y/z are fractions of the head size,
	-- y = 0.5 is the top of the head, z = -0.5 the face.
	local function H(x: number, y: number, z: number): Vector3
		return Vector3.new(x * hs.X, y * hs.Y, z * hs.Z)
	end
	local function ellipsoid(cx: number, cy: number, cz: number, rx: number, ry: number, rz: number, color: Color3, mat: Enum.Material?): Spec
		return { size = H(rx * 2, ry * 2, rz * 2), cf = CFrame.new(H(cx, cy, cz)), color = color, material = mat, mesh = "Sphere" }
	end

	-- Hats grow to sit on top of big hair.
	local hatScale = if look.hair == "afro" then 1.45 elseif look.hair == "dreads" or look.hair == "curlytop" or look.hair == "braids" then 1.1 else 1
	local hatLift = (hatScale - 1) * 0.45

	local hat, hatV = Look.worn(look, "hat")
	if hat and hatV then
		local c1, c2 = hatV.c1, hatV.c2
		local m = material(hat.material, FABRIC)
		local k = hatScale
		local function HH(x: number, y: number, z: number): Vector3
			return H(x * k, hatLift + y * k, z * k)
		end
		local specs: { Spec } = {}
		if hat.kind == "cap" or hat.kind == "backcap" then
			specs = {
				{ size = HH(1.12, 0.8, 1.2), cf = CFrame.new(HH(0, 0.3, 0.03)), color = c1, material = m, mesh = "Sphere" },
				{ size = Vector3.new(0.06, hs.X * k * 0.95, hs.Z * k * 0.95), cf = CFrame.new(HH(0, 0.17, -0.48)) * CFrame.Angles(if hat.kind == "cap" then -0.06 else -0.12, 0, 0) * CFrame.Angles(0, 0, math.pi / 2), color = c2, material = m, mesh = "Cylinder" },
				{ size = HH(0.12, 0.07, 0.12), cf = CFrame.new(HH(0, 0.69, 0.03)), color = c2, material = m, mesh = "Sphere" },
			}
			if hat.kind == "backcap" then
				for _, spec in specs do
					spec.cf = CFrame.Angles(0, math.pi, 0) * spec.cf
				end
			end
		elseif hat.kind == "beanie" then
			local tall = if hat.style == "pom" then 1.0 else 0.9
			specs = {
				{ size = HH(1.22, tall, 1.24), cf = CFrame.new(HH(0, 0.29, 0.02)), color = c1, material = m, mesh = "Sphere" },
				vdisc(HH(0, 0.14, 0.02), hs.Y * k * 0.24, hs.X * k * 1.27, hs.Z * k * 1.29, darker(c1, 0.1), m),
			}
			if hat.style == "pom" then
				table.insert(specs, { size = HH(0.34, 0.34, 0.34), cf = CFrame.new(HH(0, 0.29 + tall / 2 + 0.1, 0.02)), color = c2, material = m, mesh = "Sphere" })
			end
		elseif hat.kind == "bucket" then
			specs = {
				vdisc(HH(0, 0.44, 0.02), hs.Y * k * 0.44, hs.X * k * 1.24, hs.Z * k * 1.26, c1, m),
				{ size = HH(1.95, 0.16, 1.95), cf = CFrame.new(HH(0, 0.22, 0.02)), color = c1, material = m, mesh = "Sphere" },
				vdisc(HH(0, 0.31, 0.02), hs.Y * k * 0.08, hs.X * k * 1.26, hs.Z * k * 1.28, c2, m),
				{ size = HH(1.1, 0.14, 1.12), cf = CFrame.new(HH(0, 0.66, 0.02)), color = c1, material = m, mesh = "Sphere" },
			}
		elseif hat.kind == "headband" then
			specs = {
				{ size = HH(1.06, 0.17, 1.06), cf = CFrame.new(HH(0, 0.27, 0)), color = c1, material = m },
				{ size = HH(0.2, 0.08, 0.03), cf = CFrame.new(HH(0, 0.27, -0.545)), color = c2, material = m },
			}
		end
		accessory("hat", Enum.AccessoryType.Hat, "HatAttachment", "Head", specs)
	end

	local face, faceV = Look.worn(look, "face")
	if face and faceV then
		local c1, c2 = faceV.c1, faceV.c2
		local eye = 0.08
		local zf = -0.5
		local specs: { Spec } = {
			{ size = Vector3.new(hs.X * 0.12, 0.035, 0.035), cf = CFrame.new(H(0, eye + 0.03, zf) + Vector3.new(0, 0, -0.045)), color = c1, material = Enum.Material.Metal },
		}
		for _, side in { -1, 1 } do
			local lensPos = H(side * 0.2, eye, zf) + Vector3.new(0, 0, -0.045)
			if face.kind == "glasses" then
				table.insert(specs, fdisc(lensPos, 0.035, hs.Y * 0.27, hs.X * 0.3, c1, Enum.Material.SmoothPlastic))
				local lens = fdisc(lensPos + Vector3.new(0, 0, -0.02), 0.02, hs.Y * 0.22, hs.X * 0.25, rgb(215, 235, 245), Enum.Material.Glass)
				lens.transparency = 0.45
				table.insert(specs, lens)
			elseif face.style == "aviator" then
				table.insert(specs, { size = Vector3.new(hs.X * 0.33, hs.Y * 0.27, 0.04), cf = CFrame.new(lensPos + Vector3.new(0, -0.02, -0.01)) * CFrame.Angles(0, 0, side * 0.12), color = c2, material = Enum.Material.Glass, mesh = "Sphere", transparency = 0.1, reflectance = 0.35 })
				table.insert(specs, { size = Vector3.new(hs.X * 0.3, 0.03, 0.03), cf = CFrame.new(lensPos + Vector3.new(0, hs.Y * 0.12, 0)), color = c1, material = Enum.Material.Metal })
			elseif face.style == "round" then
				table.insert(specs, fdisc(lensPos, 0.035, hs.Y * 0.26, hs.X * 0.28, c1, Enum.Material.SmoothPlastic))
				local lens = fdisc(lensPos + Vector3.new(0, 0, -0.02), 0.02, hs.Y * 0.22, hs.X * 0.24, c2, Enum.Material.Glass)
				lens.transparency = 0.1
				lens.reflectance = 0.25
				table.insert(specs, lens)
			else
				table.insert(specs, { size = Vector3.new(hs.X * 0.32, hs.Y * 0.2, 0.04), cf = CFrame.new(lensPos), color = c2, material = Enum.Material.Glass, transparency = 0.1, reflectance = 0.3 })
			end
			-- hinge + temple running back along the side of the head
			table.insert(specs, { size = Vector3.new(hs.X * 0.16, 0.03, 0.03), cf = CFrame.new(H(side * 0.42, eye + 0.03, zf) + Vector3.new(side * 0.02, 0, -0.045)), color = c1, material = Enum.Material.Metal })
			table.insert(specs, { size = Vector3.new(0.03, 0.03, hs.Z * 0.55), cf = CFrame.new(H(side * 0.5, eye + 0.03, -0.24) + Vector3.new(side * 0.035, 0, 0)), color = c1, material = Enum.Material.Metal })
		end
		accessory("face", Enum.AccessoryType.Face, "FaceFrontAttachment", "Head", specs)
	end

	local ears, earsV = Look.worn(look, "ears")
	if ears and earsV then
		local m = material(ears.material, Enum.Material.Metal)
		local specs: { Spec } = {}
		for _, side in { -1, 1 } do
			table.insert(specs, { size = Vector3.new(0.11, 0.11, 0.11) * hs.X, cf = CFrame.new(H(side * 0.5, -0.06, 0.06) + Vector3.new(side * 0.02, 0, 0)), color = earsV.c1, material = m, mesh = "Sphere", reflectance = if ears.style == "iced" then 0.5 else 0.2 })
		end
		accessory("ears", Enum.AccessoryType.Face, "FaceCenterAttachment", "Head", specs)
	end

	local neck, neckV = Look.worn(look, "neck")
	if neck and neckV and ut then
		local m = material(neck.material, Enum.Material.Foil)
		local X, Y, Z = ut.size.X, ut.size.Y, ut.size.Z
		local iced = neck.style == "iced"
		local dip = Y * 0.32
		local bottomY = Y / 2 - 0.04 - dip
		local specs: { Spec } = {
			fdisc(Vector3.new(0, bottomY - 0.16, -Z / 2 - 0.05), 0.05, 0.3, 0.3, neckV.c2, m),
		}
		specs[1].reflectance = if iced then 0.5 else 0.3
		local links = 15
		for i = 0, links - 1 do
			local t = -1 + 2 * i / (links - 1)
			table.insert(specs, {
				size = Vector3.one * (if iced then 0.12 else 0.1),
				cf = CFrame.new(t * X * 0.2, Y / 2 - 0.04 - (1 - t * t) * dip, -Z / 2 - 0.03),
				color = if iced then neckV.c2 else neckV.c1,
				material = m,
				mesh = "Sphere",
				reflectance = if iced then 0.5 else 0.3,
			})
		end
		-- the chain going round the back of the neck
		table.insert(specs, vdisc(Vector3.new(0, Y / 2 + 0.01, 0.05), 0.07, X * 0.44, Z * 0.86, neckV.c1, m))
		accessory("neck", Enum.AccessoryType.Neck, "NeckAttachment", "UpperTorso", specs)
	end

	local function wristItem(slot: string, prefix: string, side: number)
		local item, variant = Look.worn(look, slot)
		local arm = seg(prefix .. "LowerArm")
		if not item or not variant or not arm then
			return
		end
		local A = arm.size
		local y = -A.Y / 2 + 0.16
		local attach = if r6 then prefix .. "GripAttachment" else prefix .. "WristRigAttachment"
		local specs: { Spec }
		if item.kind == "watch" then
			local m = material(item.material, Enum.Material.Metal)
			specs = {
				{ size = Vector3.new(0.06, 0.34, 0.34), cf = CFrame.new(side * (A.X / 2 + 0.05), y, 0), color = variant.c1, material = m, shape = Enum.PartType.Cylinder, reflectance = 0.2 },
				{ size = Vector3.new(0.02, 0.26, 0.26), cf = CFrame.new(side * (A.X / 2 + 0.085), y, 0), color = variant.c2, material = Enum.Material.SmoothPlastic, shape = Enum.PartType.Cylinder },
				{ size = Vector3.new(A.X + 0.06, 0.18, A.Z + 0.06), cf = CFrame.new(0, y, 0), color = if item.material == "Metal" then rgb(60, 40, 30) else variant.c1, material = if item.material == "Metal" then FABRIC else m },
			}
		else
			specs = {
				{ size = Vector3.new(A.X + 0.1, 0.32, A.Z + 0.1), cf = CFrame.new(0, y + 0.04, 0), color = variant.c1, material = FABRIC },
				{ size = Vector3.new(A.X + 0.11, 0.06, A.Z + 0.11), cf = CFrame.new(0, y + 0.04, 0), color = variant.c2, material = FABRIC },
			}
		end
		accessory(slot, Enum.AccessoryType.Unknown, attach, prefix .. "LowerArm", specs)
	end
	wristItem("wrist", "Left", -1)
	wristItem("band", "Right", 1)

	local bag, bagV = Look.worn(look, "back")
	if bag and bagV and ut then
		local c1, c2 = bagV.c1, bagV.c2
		local m = material(bag.material, FABRIC)
		local X, Y, Z = ut.size.X, ut.size.Y, ut.size.Z
		local specs: { Spec }
		if bag.kind == "sling" then
			specs = {
				{ size = Vector3.new(X * 0.5, 0.5, 0.34), cf = CFrame.new(X * 0.1, -Y * 0.32, Z / 2 + 0.17) * CFrame.Angles(0, 0, -0.25), color = c1, material = m },
				{ size = Vector3.new(X * 0.4, 0.05, 0.36), cf = CFrame.new(X * 0.1, -Y * 0.25, Z / 2 + 0.17) * CFrame.Angles(0, 0, -0.25), color = c2, material = Enum.Material.Metal },
				{ size = Vector3.new(0.13, Y * 1.3, 0.04), cf = CFrame.new(0, 0, -Z / 2 - 0.025) * CFrame.Angles(0, 0, 0.8), color = c2, material = m },
				{ size = Vector3.new(0.13, Y * 1.3, 0.04), cf = CFrame.new(0, 0, Z / 2 + 0.025) * CFrame.Angles(0, 0, -0.8), color = c2, material = m },
			}
		else
			specs = {
				{ size = Vector3.new(X * 0.72, Y * 0.78, 0.5), cf = CFrame.new(0, -Y * 0.05, Z / 2 + 0.26), color = c1, material = m },
				{ size = Vector3.new(X * 0.72, 0.36, 0.5), cf = CFrame.new(0, Y * 0.34, Z / 2 + 0.26), color = c1, material = m, mesh = "Sphere" },
				{ size = Vector3.new(X * 0.56, Y * 0.3, 0.16), cf = CFrame.new(0, -Y * 0.2, Z / 2 + 0.58), color = c2, material = m },
				{ size = Vector3.new(X * 0.56, 0.04, 0.17), cf = CFrame.new(0, -Y * 0.08, Z / 2 + 0.58), color = SILVER, material = Enum.Material.Metal },
			}
			for _, side in { -1, 1 } do
				table.insert(specs, { size = Vector3.new(0.14, Y * 0.9, 0.05), cf = CFrame.new(side * X * 0.22, -Y * 0.02, -Z / 2 - 0.025), color = c2, material = m })
				table.insert(specs, { size = Vector3.new(0.14, 0.06, Z + 0.1), cf = CFrame.new(side * X * 0.22, Y / 2 + 0.02, 0), color = c2, material = m })
			end
		end
		accessory("back", Enum.AccessoryType.Back, "BodyBackAttachment", "UpperTorso", specs)
	end

	-------------------------------------------------------------------------
	-- 5. Barber: hair + facial hair
	-------------------------------------------------------------------------
	local hairColor = Look.hairColor(look.hairColor)
	local HAIR_MAT = Enum.Material.Fabric
	local hairSpecs: { Spec } = {}
	local function addHair(spec: Spec)
		table.insert(hairSpecs, spec)
	end
	-- Short base cap: a top dome plus a back piece down to the nape.
	local function cap(thick: number, color: Color3)
		addHair(ellipsoid(0, 0.28, 0.02, 0.54 + thick, 0.31 + thick, 0.555 + thick, color, HAIR_MAT))
		addHair(ellipsoid(0, 0.08, 0.1, 0.525 + thick, 0.3, 0.45 + thick, color, HAIR_MAT))
	end
	-- Point on the top dome's surface (lateral fraction s, angle phi from the top).
	local function domePoint(s: number, phi: number, grow: number): Vector3
		local w = math.sqrt(math.max(0, 1 - s * s))
		return Vector3.new(0.56 * s, 0.28 + (0.33 + grow) * w * math.cos(phi), 0.02 + (0.57 + grow) * w * math.sin(phi))
	end

	local style = look.hair
	if style == "buzz" then
		cap(0, hairColor)
	elseif style == "fade" then
		addHair(ellipsoid(0, 0.31, 0.02, 0.545, 0.34, 0.56, hairColor, HAIR_MAT))
		addHair(ellipsoid(0, 0.1, 0.06, 0.515, 0.22, 0.5, hairColor:Lerp(skin, 0.55), HAIR_MAT))
	elseif style == "waves" then
		cap(0.005, hairColor)
		local ridge = lighter(hairColor, 0.22)
		for _, y in { 0.55, 0.48, 0.41, 0.34 } do
			local f = math.sqrt(math.max(0, 1 - ((y - 0.28) / 0.315) ^ 2))
			addHair(vdisc(H(0, y, 0.02), 0.022 * hs.Y, hs.X * (1.09 * f + 0.025), hs.Z * (1.12 * f + 0.025), ridge, HAIR_MAT))
		end
	elseif style == "curlytop" then
		cap(0, hairColor)
		addHair(ellipsoid(0, 0.52, 0.02, 0.48, 0.24, 0.5, hairColor, HAIR_MAT))
		local n = 0
		for _, ringDef in { { 0.28, 9 }, { 0.62, 6 }, { 1.0, 1 } } do
			local elev, count = ringDef[1], ringDef[2]
			for i = 1, count do
				n += 1
				local theta = (i / count) * math.pi * 2 + elev
				local r = math.cos(elev * math.pi / 2)
				local pos = Vector3.new(0.47 * r * math.sin(theta), 0.52 + 0.24 * math.sin(elev * math.pi / 2), 0.02 + 0.49 * r * math.cos(theta))
				addHair(ellipsoid(pos.X, pos.Y, pos.Z, 0.12, 0.11, 0.12, if n % 2 == 0 then hairColor else lighter(hairColor, 0.08), HAIR_MAT))
			end
		end
	elseif style == "afro" then
		addHair(ellipsoid(0, 0.52, 0.16, 0.78, 0.62, 0.74, hairColor, HAIR_MAT))
		for i = 1, 12 do
			local theta = i / 12 * math.pi * 2
			local elev = if i % 2 == 0 then 0.35 else 0.75
			local pos = Vector3.new(0.7 * math.cos(elev) * math.sin(theta), 0.52 + 0.56 * math.sin(elev), 0.16 + 0.66 * math.cos(elev) * math.cos(theta))
			addHair(ellipsoid(pos.X, pos.Y, pos.Z, 0.17, 0.16, 0.17, lighter(hairColor, 0.05), HAIR_MAT))
		end
	elseif style == "braids" then
		cap(0, darker(hairColor, 0.15))
		local rows = { -0.62, -0.37, -0.12, 0.12, 0.37, 0.62 }
		for _, s in rows do
			local steps = 7
			for i = 0, steps - 1 do
				local phi = math.rad(-72 + i * (210 / (steps - 1)))
				local p = domePoint(s, phi, 0.03)
				local ahead = domePoint(s, phi + 0.1, 0.03)
				local world, worldAhead = H(p.X, p.Y, p.Z), H(ahead.X, ahead.Y, ahead.Z)
				addHair({ size = Vector3.new(0.1 * hs.X, 0.1 * hs.X, 0.2 * hs.Z), cf = CFrame.lookAt(world, worldAhead), color = hairColor, material = HAIR_MAT, mesh = "Sphere" })
			end
		end
	elseif style == "dreads" then
		cap(0.02, hairColor)
		for layer = 0, 1 do
			local count = if layer == 0 then 15 else 11
			local spread = math.rad(if layer == 0 then 125 else 110)
			for i = 0, count - 1 do
				local psi = -spread + 2 * spread * i / (count - 1)
				local radius = 0.58 + layer * 0.05
				local length = (0.95 - layer * 0.2) * hs.Y
				local out = Vector3.new(math.sin(psi), 0, math.cos(psi))
				local topPoint = H(radius * out.X, 0.22 + layer * 0.12, 0.02 + radius * out.Z)
				local tilt = 0.14 + layer * 0.06
				local up = Vector3.new(0, math.cos(tilt), 0) - out * math.sin(tilt)
				local centre = topPoint - up * (length / 2)
				local tangent = Vector3.new(math.cos(psi), 0, -math.sin(psi))
				addHair({
					size = Vector3.new(0.14 * hs.X, length, 0.14 * hs.X),
					cf = CFrame.fromMatrix(centre, tangent, up),
					color = if i % 3 == 0 then lighter(hairColor, 0.06) else hairColor,
					material = HAIR_MAT,
					mesh = "Sphere",
				})
			end
		end
	end
	if #hairSpecs > 0 then
		accessory("hair", Enum.AccessoryType.Hair, "HairAttachment", "Head", hairSpecs)
	end

	local facial = look.facial
	if facial ~= "" then
		local beard: { Spec } = {}
		local function moustache()
			for _, side in { -1, 1 } do
				table.insert(beard, { size = H(0.24, 0.085, 0.08), cf = CFrame.new(H(side * 0.1, -0.08, -0.5)) * CFrame.Angles(0, 0, side * 0.22), color = hairColor, material = HAIR_MAT, mesh = "Sphere" })
			end
		end
		moustache()
		if facial == "goatee" then
			table.insert(beard, ellipsoid(0, -0.36, -0.46, 0.13, 0.11, 0.07, hairColor, HAIR_MAT))
			for _, side in { -1, 1 } do
				table.insert(beard, ellipsoid(side * 0.17, -0.21, -0.485, 0.035, 0.12, 0.03, hairColor, HAIR_MAT))
			end
		elseif facial == "beard" then
			table.insert(beard, ellipsoid(0, -0.36, -0.08, 0.54, 0.27, 0.48, hairColor, HAIR_MAT))
			for _, side in { -1, 1 } do
				table.insert(beard, ellipsoid(side * 0.51, -0.05, 0.02, 0.03, 0.22, 0.1, hairColor, HAIR_MAT))
			end
		end
		accessory("facial", Enum.AccessoryType.Face, "FaceFrontAttachment", "Head", beard)
	end
end

return ShopsConfig
