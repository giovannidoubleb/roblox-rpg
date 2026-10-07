--!strict
-- CITY GRIND: shared tuning values. Lives in ReplicatedStorage.CityGrind.Config
-- so the server and every client read the same numbers.

local Config = {}

Config.DATASTORE_NAME = "CityGrind_PlayerData_v1"
Config.AUTOSAVE_SECONDS = 120
Config.SESSION_LOCK_SECONDS = 180

Config.STARTING_CASH = 500
Config.MAX_CASH = 1_000_000_000
Config.MAX_LEVEL = 100
Config.MAX_TRANSACTIONS = 25

-- Total XP needed to go from `level` to `level + 1`.
function Config.xpToNext(level: number): number
	return math.floor(100 * level ^ 1.5)
end

Config.REPUTATION_RANKS = {
	{ min = 0, name = "Nobody" },
	{ min = 100, name = "Known" },
	{ min = 500, name = "Respected" },
	{ min = 1000, name = "Local Star" },
	{ min = 2500, name = "City Famous" },
	{ min = 5000, name = "Celebrity" },
	{ min = 10000, name = "Legend" },
}

function Config.reputationRank(rep: number): string
	local name = Config.REPUTATION_RANKS[1].name
	for _, rank in Config.REPUTATION_RANKS do
		if rep >= rank.min then
			name = rank.name
		end
	end
	return name
end

-- Fame (section 86-87) is separate from reputation: it comes from followers,
-- viral posts, events and social activity.
Config.FAME_LEVELS = {
	{ min = 0, name = "Unknown" },
	{ min = 50, name = "Recognized" },
	{ min = 250, name = "Popular" },
	{ min = 750, name = "Influencer" },
	{ min = 2000, name = "Star" },
	{ min = 5000, name = "Celebrity" },
	{ min = 12000, name = "Icon" },
	{ min = 25000, name = "Legend" },
}

function Config.fameLevel(fame: number): string
	local name = Config.FAME_LEVELS[1].name
	for _, level in Config.FAME_LEVELS do
		if fame >= level.min then
			name = level.name
		end
	end
	return name
end

-- Attribute names. Stats are 1-99 like a sports game rating.
Config.STATS = {
	"Strength", "Speed", "Stamina", "Vertical",
	"Shooting", "BallHandling", "Passing", "Defense", "Finishing",
}

-- Movement. Stamina stat (1-99) scales max stamina and recovery.
Config.WALK_SPEED = 14
Config.SPRINT_SPEED = 24
Config.CROUCH_SPEED = 7
Config.SLIDE_SPEED = 34
Config.SLIDE_SECONDS = 0.7
Config.SLIDE_COST = 15
Config.SPRINT_DRAIN_PER_SEC = 12
Config.MIN_SPRINT_STAMINA = 10

function Config.maxStamina(staminaStat: number): number
	return 100 + (staminaStat - 1) * 2 -- 100 at stat 1, ~296 at stat 99
end

function Config.staminaRegen(staminaStat: number): number
	return 14 + staminaStat * 0.25 -- per second
end

-- Neighborhood run route rewards (server validated).
Config.RUN_REWARD_XP = 40
Config.RUN_REWARD_CASH = 25
Config.RUN_STAMINA_STAT_XP = 20 -- progress toward +1 Stamina stat
Config.RUN_COOLDOWN = 45
Config.STAT_XP_PER_POINT = 100

Config.DRINK_PRICE = 5

Config.WALLPAPERS = {
	{ name = "Sunset", top = Color3.fromRGB(255, 120, 80), bottom = Color3.fromRGB(90, 40, 140) },
	{ name = "Court", top = Color3.fromRGB(255, 160, 40), bottom = Color3.fromRGB(150, 60, 20) },
	{ name = "Midnight", top = Color3.fromRGB(30, 40, 90), bottom = Color3.fromRGB(5, 5, 20) },
	{ name = "Ocean", top = Color3.fromRGB(60, 200, 230), bottom = Color3.fromRGB(10, 60, 140) },
	{ name = "Mint", top = Color3.fromRGB(120, 230, 170), bottom = Color3.fromRGB(20, 110, 90) },
}

Config.UI_SCALES = { 0.8, 0.9, 1, 1.1, 1.25 }
-- "Auto" follows Roblox's own graphics quality slider.
Config.GRAPHICS_LEVELS = { "Auto", "Low", "Medium", "High" }

-- Basketball (sections 70, 71). Distances are in studs.
Config.Ball = {
	DIAMETER = 1.5,
	GRAVITY = 90, -- the ball floats a little so shots arc like real ones
	PICKUP_RANGE = 3.4,
	STEAL_RANGE = 5.5,
	STEAL_COOLDOWN = 1.2,
	REGRAB_COOLDOWN = 0.6,
	PERFECT_RELEASE = 0.55, -- seconds of holding the shot button
	RELEASE_WINDOW = 0.45, -- how far from perfect still counts for anything
	PERFECT_TOLERANCE = 0.06,
	MAX_SHOT_RANGE = 60,
	THREE_POINT_RANGE = 19,
	DUNK_RANGE = 6,
	BLOCK_RANGE = 5,
	CONTEST_RANGE = 6,
	PASS_RANGE = 60,
	FREE_BALLS_PER_COURT = 6,
	FREE_BALL_IDLE_SECONDS = 60,
}

Config.Game = {
	TARGET_SCORE = 11,
	TIME_LIMIT = 6 * 60,
	COUNTDOWN = 5,
	MAX_TEAM_SIZE = 3,
	MIN_SECONDS_FOR_REWARDS = 60,
	MIN_POINTS_FOR_REWARDS = 5,
	WIN_CASH = 60,
	WIN_XP = 80,
	WIN_REP = 15,
	LOSS_CASH = 20,
	LOSS_XP = 30,
	LOSS_REP = 3,
}

return Config
