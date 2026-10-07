-- CITY GRIND: leaderboard definitions shared by server and client (section 98).
-- Every board is an OrderedDataStore "CityGrind_LB_<statId>_v1"; the season
-- boards add "_S<season number>". Fastest times are lower-is-better and are
-- stored as whole centiseconds (OrderedDataStores only hold integers).

local LeaderboardsConfig = {}

export type Stat = {
	id: string,
	label: string,
	short: string,
	icon: string,
	color: Color3,
	lowerBetter: boolean, -- fastest times
	format: string, -- "number" | "cash" | "time"
	rule: string, -- "latest" (value can fall, e.g. cash) | "best" (max / min kept)
	seasonal: boolean, -- also has a "This season" board
	crew: boolean?, -- keyed by crew id instead of a player
}

local function S(id, label, short, icon, color, format, rule, seasonal, lowerBetter, crew): Stat
	return { id = id, label = label, short = short, icon = icon, color = color, format = format, rule = rule, seasonal = seasonal, lowerBetter = lowerBetter == true, crew = crew }
end

-- Order = tab order in the phone app.
LeaderboardsConfig.STATS = {
	S("level", "Level", "LEVEL", "⭐", Color3.fromRGB(90, 170, 255), "number", "best", false),
	S("cash", "Cash", "CASH", "💵", Color3.fromRGB(110, 230, 120), "cash", "latest", false),
	S("reputation", "Reputation", "REP", "🔥", Color3.fromRGB(255, 120, 60), "number", "best", false),
	S("fame", "Fame", "FAME", "📸", Color3.fromRGB(255, 90, 200), "number", "best", false),
	S("rating", "Hoops Rating", "RATING", "🏆", Color3.fromRGB(255, 200, 60), "number", "best", true),
	S("wins", "Wins", "WINS", "🏀", Color3.fromRGB(255, 150, 40), "number", "best", true),
	S("points", "Points", "POINTS", "🎯", Color3.fromRGB(240, 90, 90), "number", "best", false),
	S("fastest5k", "Fastest 5K", "5K", "🏃", Color3.fromRGB(80, 220, 200), "time", "best", false, true),
	S("fastestRace", "Fastest Lap Race", "RACE", "🏎️", Color3.fromRGB(255, 80, 60), "time", "best", true, true),
	S("crewRating", "Crew Rating", "CREWS", "🛡️", Color3.fromRGB(200, 100, 255), "number", "latest", false, false, true),
}

LeaderboardsConfig.BY_ID = {} :: { [string]: Stat }
for _, s in LeaderboardsConfig.STATS do
	LeaderboardsConfig.BY_ID[s.id] = s
end

LeaderboardsConfig.TOP_N = 50 -- entries cached / shown per board
LeaderboardsConfig.ARCHIVE_N = 100 -- entries kept per archived season board
LeaderboardsConfig.WRITE_COOLDOWN = 60 -- seconds between writes for one player on one board
LeaderboardsConfig.REFRESH_SECONDS = 120 -- global top lists re-read this often
LeaderboardsConfig.POLL_SECONDS = 30 -- server re-reads player attributes / saves this often
LeaderboardsConfig.BUDGET_RESERVE = 6 -- leave this many requests of each budget for other systems
LeaderboardsConfig.ARCHIVES_KEPT = 20 -- archived seasons listed

-- World boards: top N shown, seconds per category.
LeaderboardsConfig.WORLD_ROWS = 8
LeaderboardsConfig.WORLD_ROTATE_SECONDS = 12
-- Categories each world board cycles through.
LeaderboardsConfig.WORLD_BOARDS = {
	Court = { title = "NEIGHBORHOOD COURT", stats = { "rating", "wins", "points", "crewRating" } },
	Grandstand = { title = "CITY SPEEDWAY", stats = { "fastestRace", "fastest5k", "crewRating", "level" } },
}

function LeaderboardsConfig.formatTime(seconds: number): string
	if seconds <= 0 then
		return "--"
	end
	local m = math.floor(seconds / 60)
	local s = seconds - m * 60
	return string.format("%d:%05.2f", m, s)
end

local function commas(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return (if n < 0 then "-" else "") .. formatted
end

-- A display string for a value on a board.
function LeaderboardsConfig.format(statId: string, value: number): string
	local s = LeaderboardsConfig.BY_ID[statId]
	if not s then
		return tostring(value)
	elseif s.format == "time" then
		return LeaderboardsConfig.formatTime(value)
	elseif s.format == "cash" then
		return "$" .. commas(value)
	end
	return commas(value)
end

-- Encoding for the OrderedDataStore (integers only).
function LeaderboardsConfig.encode(statId: string, value: number): number
	local s = LeaderboardsConfig.BY_ID[statId]
	if s and s.format == "time" then
		return math.floor(value * 100 + 0.5)
	end
	return math.floor(value)
end

function LeaderboardsConfig.decode(statId: string, stored: number): number
	local s = LeaderboardsConfig.BY_ID[statId]
	if s and s.format == "time" then
		return stored / 100
	end
	return stored
end

-- True when `a` is a better value than `b` on this board.
function LeaderboardsConfig.better(statId: string, a: number, b: number): boolean
	local s = LeaderboardsConfig.BY_ID[statId]
	if s and s.lowerBetter then
		return a > 0 and (b <= 0 or a < b)
	end
	return a > b
end

return LeaderboardsConfig
