-- CITY GRIND: crew battles (section 62). Tuning shared by server and client.
-- A crew leader or officer challenges another crew to one format; the other
-- crew's leader / officer accepts inside the accept window; the battle runs
-- for the format's window and scores come from what crew members really do.

local CrewBattlesConfig = {}

export type Format = {
	id: string,
	label: string,
	icon: string,
	color: Color3,
	minutes: number,
	unit: string,
	desc: string,
}

CrewBattlesConfig.FORMATS = {
	{
		id = "Basketball",
		label = "Basketball",
		icon = "🏀",
		color = Color3.fromRGB(255, 140, 40),
		minutes = 20,
		unit = "pts",
		desc = "Points your crew scores in games against the other crew (same court) + 5 per game won anywhere.",
	},
	{
		id = "Racing",
		label = "Racing",
		icon = "🏎️",
		color = Color3.fromRGB(255, 80, 60),
		minutes = 20,
		unit = "pts",
		desc = "Race finishes: 1st 10 · 2nd 7 · 3rd 5 · other 3, +2 for each rival crew member beaten in the same race.",
	},
	{
		id = "Running",
		label = "Running",
		icon = "🏃",
		color = Color3.fromRGB(80, 220, 200),
		minutes = 15,
		unit = "pts",
		desc = "1 pt per 10 studs run on foot, +100 per Neighborhood route run, +300 per City 5K finish.",
	},
	{
		id = "TreasureHunt",
		label = "Treasure Hunt",
		icon = "💎",
		color = Color3.fromRGB(90, 200, 255),
		minutes = 30,
		unit = "pts",
		desc = "100 pts per cache your crew finds in Treasure Hunt events during the battle.",
	},
	{
		id = "CityChallenge",
		label = "City Challenge",
		icon = "🏙️",
		color = Color3.fromRGB(200, 100, 255),
		minutes = 30,
		unit = "",
		desc = "Crew-wide total of one city metric for 30 minutes.",
	},
}

CrewBattlesConfig.BY_ID = {} :: { [string]: Format }
for _, f in CrewBattlesConfig.FORMATS do
	CrewBattlesConfig.BY_ID[f.id] = f
end

-- City Challenge metrics.
CrewBattlesConfig.METRICS = {
	{ id = "jobs", label = "Job shifts", icon = "💼", unit = "shifts", desc = "Job shifts completed." },
	{ id = "distance", label = "Distance run", icon = "👟", unit = "studs", desc = "Studs covered on foot." },
	{ id = "buckets", label = "Buckets", icon = "🎯", unit = "pts", desc = "Basketball points scored on any court." },
}
CrewBattlesConfig.METRIC_BY_ID = {} :: { [string]: any }
for _, m in CrewBattlesConfig.METRICS do
	CrewBattlesConfig.METRIC_BY_ID[m.id] = m
end

CrewBattlesConfig.ACCEPT_SECONDS = 120 -- challenge expires if not accepted
CrewBattlesConfig.COUNTDOWN_SECONDS = 30 -- after accepting, before scoring starts
CrewBattlesConfig.FINALIZE_GRACE = 20 -- seconds after the end for other servers' last scores (they broadcast every 10 s)
CrewBattlesConfig.CHALLENGE_COOLDOWN = 60 -- per issuing player
CrewBattlesConfig.SCORE_BROADCAST_SECONDS = 10 -- cross-server score updates

-- Rating (Elo-like)
CrewBattlesConfig.START_RATING = 1000
CrewBattlesConfig.K = 32

-- Anti-farming: only this many rated battles per pair of crews per 24 h (later ones are
-- unrated: no rating change, cup points or rewards), and each player collects battle
-- rewards at most this many times per UTC day. A battle where one side scored nothing
-- is also unrated (uncontested).
CrewBattlesConfig.PAIR_RATED_PER_DAY = 2
CrewBattlesConfig.DAILY_REWARDED_BATTLES = 5

-- Rewards for members of either crew who scored in a rated battle
CrewBattlesConfig.WIN_REWARD = { cash = 1500, xp = 300, rep = 25, crewRep = 40 }
CrewBattlesConfig.DRAW_REWARD = { cash = 600, xp = 150, rep = 10, crewRep = 15 }
CrewBattlesConfig.LOSS_REWARD = { cash = 250, xp = 80, rep = 0, crewRep = 5 } -- only if they scored

-- Weekly City Crew Cup: points per battle result, top crews rewarded the next week.
CrewBattlesConfig.CUP_POINTS = { win = 3, draw = 1 }
CrewBattlesConfig.CUP_REWARDS = {
	{ cash = 10000, xp = 2000, rep = 100 },
	{ cash = 6000, xp = 1200, rep = 60 },
	{ cash = 3500, xp = 800, rep = 40 },
}
-- Weeks start Monday 00:00 UTC (1970-01-05 was a Monday).
CrewBattlesConfig.WEEK_EPOCH = 4 * 86400

function CrewBattlesConfig.week(t: number): number
	return math.floor((t - CrewBattlesConfig.WEEK_EPOCH) / 604800)
end

function CrewBattlesConfig.weekEnds(week: number): number
	return CrewBattlesConfig.WEEK_EPOCH + (week + 1) * 604800
end

-- Elo expected score of A against B.
function CrewBattlesConfig.expected(ra: number, rb: number): number
	return 1 / (1 + 10 ^ ((rb - ra) / 400))
end

function CrewBattlesConfig.formatName(formatId: string, metric: string?): string
	local f = CrewBattlesConfig.BY_ID[formatId]
	if not f then
		return formatId
	end
	if formatId == "CityChallenge" and metric then
		local m = CrewBattlesConfig.METRIC_BY_ID[metric]
		if m then
			return f.label .. ": " .. m.label
		end
	end
	return f.label
end

function CrewBattlesConfig.unit(formatId: string, metric: string?): string
	if formatId == "CityChallenge" and metric then
		local m = CrewBattlesConfig.METRIC_BY_ID[metric]
		return m and m.unit or ""
	end
	local f = CrewBattlesConfig.BY_ID[formatId]
	return f and f.unit or ""
end

function CrewBattlesConfig.clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

return CrewBattlesConfig
