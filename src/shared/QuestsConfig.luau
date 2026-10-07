-- CITY GRIND: quests, achievements and daily login tuning (spec 78, 79, 80, 113).
-- Shared so the phone shows exactly what the server checks. Every goal is a
-- "metric": a lifetime number the server reads from saved data (see
-- server/Quests.luau metric()). Daily/weekly quests count the metric's growth
-- since the quest was handed out; achievements and story missions compare the
-- lifetime value itself.

local QuestsConfig = {}

QuestsConfig.STUDS_PER_METRE = 3.57 -- same scale as the phone's GPS

-- How each metric is printed.
QuestsConfig.FORMAT = {
	earned = "cash",
	runM = "distance",
	driveM = "distance",
}

local function commas(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return formatted
end
QuestsConfig.commas = commas

function QuestsConfig.formatValue(metric: string, n: number): string
	local kind = QuestsConfig.FORMAT[metric]
	if kind == "cash" then
		return "$" .. commas(n)
	elseif kind == "distance" then
		if n >= 1000 then
			return string.format("%.1f km", n / 1000)
		end
		return commas(n) .. " m"
	end
	return commas(n)
end

---------------------------------------------------------------------------
-- Daily / weekly quests (78, 79)
---------------------------------------------------------------------------
-- `goal` may be a function of the player's level. `needs` (optional) names a
-- server-side eligibility check (see Quests.luau ELIGIBLE).
export type QuestDef = {
	id: string,
	metric: string,
	text: string, -- %s = formatted goal
	icon: string,
	goal: number | (level: number) -> number,
	needs: string?,
}

local function round(n: number, step: number): number
	return math.max(step, math.floor(n / step + 0.5) * step)
end

-- "Earn $5,000 (scaled to level)": $600 at level 1, $5,000 around level 20.
function QuestsConfig.dailyEarnGoal(level: number): number
	return math.min(round(400 + level * 230, 100), 40_000)
end

QuestsConfig.DAILY_POOL = {
	{ id = "d_points", metric = "points", icon = "🏀", text = "Score %s points in pickup games", goal = 30 },
	{ id = "d_jobs", metric = "jobs", icon = "💼", text = "Complete %s job shifts", goal = 3 },
	{ id = "d_run", metric = "runM", icon = "👟", text = "Run %s on foot", goal = 2000 },
	{ id = "d_earn", metric = "earned", icon = "💵", text = "Earn %s", goal = QuestsConfig.dailyEarnGoal },
	{ id = "d_gym", metric = "reps", icon = "🏋️", text = "Do %s good reps at the gym", goal = 50 },
	{ id = "d_wins", metric = "wins", icon = "🏆", text = "Win %s pickup games", goal = 2 },
	{ id = "d_photos", metric = "photos", icon = "📸", text = "Take %s photos", goal = 3 },
	{ id = "d_threes", metric = "threes", icon = "🎯", text = "Hit %s threes in games", goal = 5 },
	{ id = "d_shots", metric = "shots", icon = "🗑️", text = "Make %s shots on any court", goal = 20 },
	{ id = "d_drive", metric = "driveM", icon = "🚗", text = "Drive %s", goal = 3000, needs = "vehicle" },
	{ id = "d_post", metric = "posts", icon = "🖼️", text = "Post %s photo to CityGram", goal = 1 },
	{ id = "d_event", metric = "events", icon = "🎉", text = "Take part in %s city event", goal = 1 },
} :: { QuestDef }

QuestsConfig.WEEKLY_POOL = {
	{ id = "w_wins", metric = "wins", icon = "🏆", text = "Win %s pickup games", goal = 10 },
	{ id = "w_earn", metric = "earned", icon = "💰", text = "Earn %s", goal = function(level: number)
		return QuestsConfig.dailyEarnGoal(level) * 10
	end },
	{ id = "w_jobs", metric = "jobs", icon = "💼", text = "Complete %s job shifts", goal = 20 },
	{ id = "w_events", metric = "events", icon = "🎉", text = "Take part in %s city events", goal = 3 },
	{ id = "w_rank", metric = "rankIndex", icon = "⭐", text = "Reach a new reputation rank", goal = 1, needs = "notLegend" },
	{ id = "w_gym", metric = "reps", icon = "🏋️", text = "Do %s good reps at the gym", goal = 300 },
	{ id = "w_run", metric = "runM", icon = "👟", text = "Run %s on foot", goal = 10000 },
	{ id = "w_points", metric = "points", icon = "🏀", text = "Score %s points in pickup games", goal = 150 },
} :: { QuestDef }

QuestsConfig.DAILY_COUNT = 3
QuestsConfig.WEEKLY_COUNT = 3

-- Rewards scale gently with level so they stay worth claiming.
function QuestsConfig.dailyReward(level: number): { cash: number, xp: number, rep: number }
	return { cash = round(150 + level * 25, 10), xp = 60 + level * 8, rep = 5 }
end

function QuestsConfig.weeklyReward(level: number): { cash: number, xp: number, rep: number }
	return { cash = round(1000 + level * 150, 50), xp = 400 + level * 40, rep = 30 }
end

---------------------------------------------------------------------------
-- Achievements (80)
---------------------------------------------------------------------------
export type Achievement = {
	id: string,
	name: string,
	desc: string,
	icon: string,
	tier: string, -- Bronze | Silver | Gold | Platinum
	metric: string?, -- nil = only unlocked by code (Quests.unlock)
	goal: number?,
	cash: number,
	xp: number,
	title: string?,
	needs: string?, -- "districts": only listed when the districts exist
}

QuestsConfig.TIER_COLORS = {
	Bronze = Color3.fromRGB(205, 127, 50),
	Silver = Color3.fromRGB(200, 205, 215),
	Gold = Color3.fromRGB(255, 200, 60),
	Platinum = Color3.fromRGB(150, 230, 255),
}

local function A(id, name, desc, icon, tier, metric, goal, cash, xp, title): Achievement
	return { id = id, name = name, desc = desc, icon = icon, tier = tier, metric = metric, goal = goal, cash = cash, xp = xp, title = title }
end

QuestsConfig.ACHIEVEMENTS = {
	-- Basketball
	A("first_bucket", "First Bucket", "Make your first shot on any court.", "🏀", "Bronze", "shots", 1, 50, 25),
	A("first_win", "First W", "Win a pickup game.", "✌️", "Bronze", "wins", 1, 100, 50),
	A("first_dunk", "First Dunk", "Throw down a dunk in a game.", "💥", "Bronze", "dunks", 1, 100, 50),
	A("points_1000", "1,000 Points", "Score 1,000 points in pickup games.", "🔥", "Silver", "points", 1000, 2000, 800, "Bucket Machine"),
	A("points_10000", "Walking Bucket", "Score 10,000 points in pickup games.", "🌋", "Platinum", "points", 10000, 20000, 6000, "Walking Bucket"),
	A("wins_10", "Run It Back", "Win 10 pickup games.", "🥉", "Bronze", "wins", 10, 500, 200),
	A("wins_100", "100 Wins", "Win 100 pickup games.", "👑", "Gold", "wins", 100, 10000, 3000, "Centurion"),
	A("threes_50", "Splash Zone", "Hit 50 threes in games.", "🎯", "Silver", "threes", 50, 1500, 600, "Sniper"),
	A("ankle_breaker", "Ankle Breaker", "Get 10 steals in games.", "🦶", "Silver", "steals", 10, 800, 300, "Ankle Breaker"),
	A("rim_protector", "Rim Protector", "Block 25 shots in games.", "🧱", "Silver", "blocks", 25, 1200, 400, "Rim Protector"),
	A("dunks_100", "Posterizer", "Dunk 100 times in games.", "🦅", "Gold", "dunks", 100, 6000, 2000, "Posterizer"),
	-- Work and money
	A("first_paycheck", "First Paycheck", "Finish your first job shift.", "💼", "Bronze", "jobs", 1, 100, 50),
	A("shifts_50", "Working Class", "Finish 50 job shifts.", "🧰", "Silver", "jobs", 50, 3000, 1000),
	A("shifts_250", "Workaholic", "Finish 250 job shifts.", "⏰", "Gold", "jobs", 250, 15000, 5000, "Workaholic"),
	A("job_level_10", "Career Climber", "Reach job level 10 in any job.", "📈", "Silver", "jobLevel", 10, 2500, 800),
	A("earned_10k", "Pocket Money", "Earn $10,000 in total.", "💵", "Bronze", "earned", 10000, 500, 300),
	A("earned_100k", "Six Figures", "Earn $100,000 in total.", "💰", "Silver", "earned", 100000, 5000, 2000, "Six Figures"),
	A("earned_1m", "$1 Million", "Earn $1,000,000 in total.", "🤑", "Platinum", "earned", 1000000, 50000, 10000, "Millionaire"),
	-- Rides and homes
	A("first_vehicle", "First Vehicle", "Buy your first vehicle.", "🚲", "Bronze", "vehicles", 1, 150, 100),
	A("vehicles_5", "Collector", "Own 5 vehicles.", "🚘", "Gold", "vehicles", 5, 8000, 2500, "Collector"),
	A("road_trip", "Road Trip", "Drive 50 km.", "🛣️", "Silver", "driveM", 50000, 3000, 1500, "Road Warrior"),
	A("marathon", "Marathoner", "Run 42 km on foot.", "🏃", "Silver", "runM", 42195, 3000, 1500, "Marathoner"),
	A("home_apartment", "First Apartment Upgrade", "Move up from the Studio.", "🏠", "Bronze", "homeTier", 2, 1000, 500),
	A("home_luxury", "Home Owner: Luxury", "Own a Luxury Apartment.", "🏙️", "Silver", "homeTier", 3, 5000, 2000),
	A("home_penthouse", "Home Owner: Penthouse", "Own a Penthouse.", "🌆", "Gold", "homeTier", 4, 15000, 5000, "Penthouse Life"),
	A("home_mansion", "Home Owner: Mansion", "Own a Mansion.", "🏰", "Platinum", "homeTier", 5, 50000, 10000, "Mogul"),
	-- Body
	A("gym_100", "First Pump", "Do 100 good reps at the gym.", "💪", "Bronze", "reps", 100, 200, 100),
	A("gym_rat", "Gym Rat", "Do 1,000 good reps at the gym.", "🏋️", "Gold", "reps", 1000, 4000, 1500, "Gym Rat"),
	-- Progress
	A("level_10", "Getting Started", "Reach level 10.", "🔟", "Bronze", "level", 10, 1000, 0),
	A("level_25", "Veteran", "Reach level 25.", "🎖️", "Silver", "level", 25, 5000, 0),
	A("level_50", "Halfway Up", "Reach level 50.", "🏅", "Gold", "level", 50, 20000, 0),
	A("level_100", "Max Level", "Reach level 100.", "💎", "Platinum", "level", 100, 100000, 0, "Maxed Out"),
	A("rep_local_star", "Local Star", "Reach 1,000 reputation.", "🌟", "Silver", "rep", 1000, 2000, 800),
	A("legend_rank", "Legend Rank", "Reach 10,000 reputation and the Legend rank.", "🐐", "Platinum", "rep", 10000, 25000, 8000, "The Legend"),
	-- Social
	A("first_friend", "New Face", "Make your first friend.", "🤝", "Bronze", "friends", 1, 100, 50),
	A("socialite", "Socialite", "Have 10 friends.", "🥂", "Silver", "friends", 10, 1500, 600, "Socialite"),
	A("crew_up", "Crew Up", "Join or start a crew.", "🛡️", "Bronze", "crew", 1, 500, 200),
	A("influencer", "Influencer", "Reach 100 followers on CityGram.", "📱", "Gold", "followers", 100, 8000, 3000, "Influencer"),
	A("viral", "Viral", "Have a CityTok video go viral.", "🚀", "Gold", "viral", 1, 5000, 2000, "Viral"),
	A("photographer", "Photographer", "Take 25 photos.", "📸", "Silver", "photos", 25, 1000, 400, "Photographer"),
	A("first_post", "Say Cheese", "Post your first photo to CityGram.", "🖼️", "Bronze", "posts", 1, 100, 50),
	A("fashionista", "Fashionista", "Own 25 clothing items.", "🧥", "Gold", "items", 25, 3000, 1000, "Fashionista"),
	-- City life
	A("first_event", "Show Up", "Take part in a city event.", "🎉", "Bronze", "events", 1, 200, 100),
	A("first_podium", "On the Podium", "Finish top 3 in a city event.", "🥇", "Silver", "podiums", 1, 1000, 400),
	A("event_champ", "Event Champion", "Win 5 city events.", "🏆", "Gold", "eventWins", 5, 6000, 2000, "Champion"),
	A("explorer", "Explorer", "Visit every district of the city.", "🗺️", "Silver", "districts", 6, 2000, 800, "Explorer"),
	A("dedicated", "Dedicated", "Claim all 7 daily login rewards in a row.", "📅", "Silver", "loginCycles", 1, 1000, 500),
	A("quest_master", "Quest Master", "Complete 50 daily or weekly quests.", "📜", "Gold", "questsDone", 50, 5000, 2000, "Quest Master"),
	A("collect_first", "Finders Keepers", "Find your first collectible.", "🔎", "Bronze", nil, nil, 100, 50),
	A("collect_set", "Set Complete", "Complete a collectible set.", "🧩", "Silver", nil, nil, 1000, 400),
	A("collect_all", "Master Collector", "Find every collectible in the city.", "🏆", "Platinum", nil, nil, 10000, 3000, "Master Collector"),
	A("secret_first", "Off the Map", "Discover a secret place.", "🗝️", "Bronze", nil, nil, 200, 100),
	A("secret_all", "City Secrets", "Discover every secret place.", "🕳️", "Gold", nil, nil, 5000, 1500, "Urban Explorer"),
	A("story_done", "Rise to the Top", "Finish the City Grind story.", "🏙️", "Platinum", nil, nil, 25000, 5000, "Top of the City"),
} :: { Achievement }

QuestsConfig.ACHIEVEMENT_BY_ID = {} :: { [string]: Achievement }
for _, a in QuestsConfig.ACHIEVEMENTS do
	QuestsConfig.ACHIEVEMENT_BY_ID[a.id] = a
end
QuestsConfig.ACHIEVEMENT_BY_ID.explorer.needs = "districts"

---------------------------------------------------------------------------
-- Daily login (113): 7-day cycle, resets when a UTC day is missed.
---------------------------------------------------------------------------
-- Labels only; the server decides the real reward in Quests.luau.
QuestsConfig.LOGIN_DAYS = {
	{ day = 1, icon = "💵", label = "Cash", kind = "cash", cash = 300 },
	{ day = 2, icon = "⭐", label = "XP Boost", kind = "xp", xp = 250 },
	{ day = 3, icon = "👕", label = "Free Clothing", kind = "cosmetic", cash = 150 },
	{ day = 4, icon = "💰", label = "More Cash", kind = "cash", cash = 600 },
	-- Every emote in the game is already free, so Day 5 grants XP instead of an emote.
	{ day = 5, icon = "🌟", label = "Big XP", kind = "xp", xp = 500 },
	{ day = 6, icon = "🎨", label = "Car Mod Voucher", kind = "voucher" },
	{ day = 7, icon = "💎", label = "Rare Reward", kind = "rare", cash = 2500, xp = 1000, rep = 25, title = "Day One" },
}

-- Free clothing for Day 3: the first one the player doesn't own yet.
QuestsConfig.LOGIN_ITEMS = { "st_graphic", "st_cap", "ath_headband", "ath_wristband", "vin_beanie", "cas_backcap", "st_bucket", "ath_tank" }

-- Cash scales a little with level so later days still matter.
function QuestsConfig.loginCash(base: number, level: number): number
	return math.floor(base * (1 + (level - 1) / 25) / 10 + 0.5) * 10
end

return QuestsConfig
