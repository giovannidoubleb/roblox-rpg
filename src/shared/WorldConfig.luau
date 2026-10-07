-- CITY GRIND: the living world (spec 65, 66, 81, 82, 89). Shared tuning for
-- server/World.luau and client/World.luau: collectible sets and candidate
-- spots, secret rewards, weather states and NPC recognition lines.

local WorldConfig = {}

---------------------------------------------------------------------------
-- Collectibles (81)
---------------------------------------------------------------------------
export type CollectibleSet = {
	id: string,
	name: string,
	icon: string,
	color: Color3,
	blurb: string,
}

WorldConfig.SETS = {
	{ id = "Balls", name = "Golden Basketballs", icon = "🏀", color = Color3.fromRGB(255, 200, 60), blurb = "Lost near courts, tracks and anywhere people hoop." },
	{ id = "Tags", name = "Graffiti Tags", icon = "🎨", color = Color3.fromRGB(255, 90, 200), blurb = "Fresh pieces in alleys, back lots and tunnels." },
	{ id = "Sneakers", name = "Vintage Sneakers", icon = "👟", color = Color3.fromRGB(90, 200, 255), blurb = "Classic pairs left up high and off the beaten path." },
	{ id = "Tapes", name = "Lost Mixtapes", icon = "📼", color = Color3.fromRGB(150, 255, 140), blurb = "Hangout spots, hideouts and places under things." },
} :: { CollectibleSet }

WorldConfig.SET_BY_ID = {} :: { [string]: CollectibleSet }
for _, s in WorldConfig.SETS do
	WorldConfig.SET_BY_ID[s.id] = s
end

-- Rewards (server decides; shown in the Collection app).
WorldConfig.ITEM_REWARD = { cash = 60, xp = 40 }
WorldConfig.SET_REWARD = { cash = 1500, xp = 600, rep = 50, fame = 25 }
WorldConfig.ALL_SETS_REWARD = { cash = 5000, xp = 2000, rep = 150, fame = 100 }
WorldConfig.COLLECT_RANGE = 9 -- studs from the item's centre the server accepts

export type Spot = {
	id: string, -- stable save key (never reuse an id for a different place)
	set: string,
	pos: Vector3, -- the server raycasts DOWN from here (<= 30 studs) to find the floor
}

local function S(id: string, set: string, x: number, y: number, z: number): Spot
	return { id = id, set = set, pos = Vector3.new(x, y, z) }
end

-- Hand-picked, reachable candidate spots. The server checks each one at build
-- time (floor below, nothing solid where the item would float) and skips any
-- that a later map change made bad, so set sizes are whatever survives.
WorldConfig.SPOTS = {
	-- The Neighborhood
	S("n01", "Balls", 100, 5, -160), -- behind the court baseline
	S("n02", "Balls", -173, 10, -80), -- top of the playground slide tower
	S("n03", "Tags", -70, 5, 88), -- alley behind Corner Mart
	S("n04", "Tags", -185, 5, 90), -- behind Threads
	S("n05", "Tags", -100, 5, -115), -- behind Maple Court
	S("n06", "Sneakers", 205, 5, -105), -- behind Iron Box
	S("n07", "Tapes", -200, 5, -107), -- by the park fountain
	S("n08", "Tapes", 70, 5, 90), -- behind Mama's Kitchen
	S("n09", "Sneakers", 150, 5, 126), -- back of the car lot
	S("n10", "Balls", -250, 5, 180), -- south field
	S("n11", "Tags", 280, 5, -200), -- north-east corner
	S("n12", "Sneakers", -280, 5, 205), -- south-west corner
	-- Downtown
	S("d01", "Sneakers", 46, 64, -706), -- Summit Tower roof
	S("d02", "Sneakers", 114, 64, -706), -- Summit Tower roof
	S("d03", "Balls", -160, 5, -300), -- the plaza
	S("d04", "Tags", -90, 5, -402), -- behind City Bank
	S("d05", "Tags", -134, 5, -428), -- alley between the bank and the bistro
	S("d06", "Tapes", 70, 5, -395), -- behind Skyline Diner
	S("d07", "Tapes", 255, 5, -515), -- parking lot
	S("d08", "Balls", 262, 5, -270), -- by the arena
	S("d09", "Tags", -195, 5, -582), -- behind the luxury stores
	S("d10", "Tapes", -30, 5, -705), -- north end of the avenue
	-- Industrial
	S("i01", "Tapes", 850, -10, -250), -- the Underground den
	S("i02", "Tags", 500, -10, -215), -- the old tunnel
	S("i03", "Tags", 100, -10, -215), -- the old tunnel
	S("i04", "Balls", 720, 5, 120), -- container yard aisle
	S("i05", "Sneakers", 395, 5, -115), -- behind Warehouse A
	S("i06", "Tapes", 395, 5, 150), -- between the smokestacks
	S("i07", "Balls", 350, 5, -480), -- race paddock
	S("i08", "Tags", 735, 5, -102), -- behind Rusty's Garage
	S("i09", "Sneakers", 615, 5, -192), -- behind the truck depot
	S("i10", "Tapes", 865, 5, -110), -- by the service tunnel gate
	-- The Beach
	S("b01", "Tapes", 150, -1.5, 548), -- under the pier
	S("b02", "Sneakers", -285, 12, 290), -- skate park deck
	S("b03", "Balls", 300, 5, 352), -- beach court
	S("b04", "Balls", 560, 5, 320), -- running track infield
	S("b05", "Tapes", -30, 5, 494), -- bonfire circle
	S("b06", "Sneakers", 160, 4, 648), -- end of the pier
	S("b07", "Tags", 40, 5, 428), -- behind the Tiki Shack
	S("b08", "Balls", 430, 5, 458), -- Muscle Beach
	S("b09", "Tapes", -120, 5, 472), -- ferris wheel
	S("b10", "Tags", -440, 3, 396), -- west boardwalk
	S("b11", "Sneakers", 860, 5, 420), -- far east sand
	S("b12", "Balls", -330, 6, 282), -- skate park fun box
	-- Luxury Hills
	S("l01", "Sneakers", -375, 114, -345), -- Sky Lounge
	S("l02", "Balls", -360, 5, -572), -- behind Prestige Motors
	S("l03", "Tapes", -476, 20, -623), -- Aurelia pool deck
	S("l04", "Tags", -720, 20, -650), -- hilltop woods
	S("l05", "Sneakers", -476, 20, -357), -- Vireo pool deck
	S("l06", "Tapes", -430, 20, -700), -- hill edge
	S("l07", "Balls", -320, 5, -660), -- foot of Penthouse One
	S("l08", "Tags", -410, 5, -300), -- below the hill
	-- Old Town
	S("o01", "Sneakers", -385, 36, 145), -- Clocktower roof
	S("o02", "Tapes", -370, 36, 160), -- Clocktower roof
	S("o03", "Tags", -715, -10, -190), -- catacombs
	S("o04", "Tapes", -698, 6, -115), -- Forgotten Cellar
	S("o05", "Tags", -380, 5, -95), -- behind the main street, by Town Hall
	S("o06", "Balls", -498, 5, 130), -- old court sideline
	S("o07", "Sneakers", -660, 5, 75), -- behind the Grand Theatre
	S("o08", "Tags", -690, 5, 200), -- behind Warehouse Lofts
	S("o09", "Tapes", -580, 5, -75), -- behind Hotel Bellmont
	S("o10", "Balls", -610, 5, -200), -- south end of the side street
	S("o11", "Tags", -500, -10, -215), -- the old tunnel
	S("o12", "Sneakers", -740, 5, 100), -- western edge
	S("o13", "Balls", -450, 5, 200), -- side street, south
	S("o14", "Balls", 20, 5, -560), -- Downtown avenue east sidewalk
} :: { Spot }

---------------------------------------------------------------------------
-- Secrets (82). Areas are parts tagged "SecretArea" (built by Districts).
---------------------------------------------------------------------------
WorldConfig.SECRET_IDS = { "CityTunnel", "IndustrialUnderground", "OldTownRooftop", "OldTownCellar", "OldTownCatacombs" }
WorldConfig.SECRET_REWARD = { cash = 400, xp = 250, rep = 25 }

---------------------------------------------------------------------------
-- Weather (66)
---------------------------------------------------------------------------
export type Weather = {
	id: string,
	label: string,
	icon: string,
	weight: number, -- chance of being picked next
	minMinutes: number,
	maxMinutes: number,
	grip: number, -- vehicle grip multiplier (Workspace attribute WeatherGrip)
	dayOnly: boolean?,
}

WorldConfig.WEATHER = {
	{ id = "Clear", label = "Clear", icon = "☀️", weight = 5, minMinutes = 4, maxMinutes = 7, grip = 1 },
	{ id = "Cloudy", label = "Cloudy", icon = "☁️", weight = 3, minMinutes = 3, maxMinutes = 6, grip = 1 },
	{ id = "Rain", label = "Rain", icon = "🌧️", weight = 2.5, minMinutes = 3, maxMinutes = 5, grip = 0.82 },
	{ id = "Storm", label = "Thunderstorm", icon = "⛈️", weight = 1, minMinutes = 2, maxMinutes = 4, grip = 0.75 },
	{ id = "Fog", label = "Fog", icon = "🌫️", weight = 1.5, minMinutes = 3, maxMinutes = 5, grip = 1 },
	{ id = "Heatwave", label = "Heatwave", icon = "🔥", weight = 1, minMinutes = 3, maxMinutes = 5, grip = 1, dayOnly = true },
} :: { Weather }

WorldConfig.WEATHER_BY_ID = {} :: { [string]: Weather }
for _, w in WorldConfig.WEATHER do
	WorldConfig.WEATHER_BY_ID[w.id] = w
end

---------------------------------------------------------------------------
-- NPC pedestrians (65) and recognition (89)
---------------------------------------------------------------------------
WorldConfig.NPC_COUNT = 24
WorldConfig.NPC_TICK = 1 / 3 -- seconds between NPC updates (3 Hz)
WorldConfig.NPC_WAKE_RANGE = 250 -- NPCs sleep (anchored, idle) with no player this close
WorldConfig.RECOGNIZE_RANGE = 14
WorldConfig.NPC_COOLDOWN = 40 -- seconds before the same NPC reacts to anyone again
WorldConfig.PLAYER_COOLDOWN = 25 -- seconds before any NPC reacts to the same player again
WorldConfig.PAIR_COOLDOWN = 300 -- seconds before the same NPC reacts to the same player again

-- Schedules: district per time slot (morning 5-11, afternoon 11-17, evening 17-21, night 21-5).
WorldConfig.SCHEDULES = {
	Commuter = { "Downtown", "Downtown", "Neighborhood", "OldTown" },
	Beachgoer = { "Neighborhood", "Beach", "Beach", "OldTown" },
	NightOwl = { "Neighborhood", "Industrial", "OldTown", "OldTown" },
	Local = { "Neighborhood", "Neighborhood", "Neighborhood", "OldTown" },
	Worker = { "Industrial", "Industrial", "Downtown", "OldTown" },
	Uptown = { "Luxury", "Beach", "Luxury", "OldTown" },
}
-- How many NPCs follow each schedule (sums to NPC_COUNT).
WorldConfig.SCHEDULE_MIX = { Commuter = 6, Beachgoer = 5, NightOwl = 3, Local = 4, Worker = 3, Uptown = 3 }

function WorldConfig.timeSlot(clockTime: number): number
	if clockTime >= 5 and clockTime < 11 then
		return 1
	elseif clockTime >= 11 and clockTime < 17 then
		return 2
	elseif clockTime >= 17 and clockTime < 21 then
		return 3
	end
	return 4
end

-- Recognition tier from reputation and fame (0 = nobody knows you yet).
function WorldConfig.recognitionTier(reputation: number, fame: number): number
	local tier = 0
	if reputation >= 100 or fame >= 50 then
		tier = 1
	end
	if reputation >= 500 or fame >= 250 then
		tier = 2
	end
	if reputation >= 2500 or fame >= 2000 then
		tier = 3
	end
	if reputation >= 10000 or fame >= 12000 then
		tier = 4
	end
	return tier
end

-- Chance an NPC reacts when you pass, per tier.
WorldConfig.RECOGNIZE_CHANCE = { 0.2, 0.4, 0.65, 0.9 }
-- "%s" is the player's display name.
WorldConfig.RECOGNIZE_LINES = {
	{ "Hey... aren't you %s?", "Wait, I've seen you around. %s, right?", "Oh, %s! Nice." },
	{ "Yo, that's %s!", "%s! Saw your highlights.", "Big fan, %s!" },
	{ "No way, it's %s! Can I get a pic?", "%s!! You're famous out here!", "Everybody look, it's %s!" },
	{ "IT'S %s! THE LEGEND!", "I can't believe it... %s!", "%s! The whole city knows you!" },
}

return WorldConfig
