-- CITY GRIND: ranked basketball and seasons tuning (spec 54, 55).
-- Shared so the phone app renders tiers, rewards and the season clock from the
-- same numbers the server uses. The server decides every result.

local RankedConfig = {}

---------------------------------------------------------------------------
-- Entry requirements
---------------------------------------------------------------------------
RankedConfig.MIN_LEVEL = 5
-- "Hooper rating": the average of the basketball stats below (each 1-99).
RankedConfig.MIN_HOOPER_RATING = 8
RankedConfig.HOOPER_STATS = { "Shooting", "BallHandling", "Passing", "Defense", "Finishing", "Vertical", "Speed" }

RankedConfig.MODES = { "1v1", "2v2" }
RankedConfig.TEAM_SIZE = { ["1v1"] = 1, ["2v2"] = 2 }

---------------------------------------------------------------------------
-- Rating (Elo with a games-played K factor: "Glicko-lite")
---------------------------------------------------------------------------
RankedConfig.START_RATING = 1000
RankedConfig.PLACEMENTS = 5 -- first ranked games of each season
RankedConfig.K_PLACEMENT = 56
RankedConfig.K_NEW = 32 -- until K_NEW_GAMES rated games in the season
RankedConfig.K_NEW_GAMES = 30
RankedConfig.K = 24
RankedConfig.MIN_CHANGE = 2 -- a rated win/loss always moves at least this much
RankedConfig.MARGIN_BONUS = 0.25 -- up to +25% K for an 11-0 style blowout
RankedConfig.STREAK_FROM = 3 -- win streaks of 3+ give a bonus...
RankedConfig.STREAK_BONUS = 2 -- ...of this many points per extra win...
RankedConfig.STREAK_BONUS_MAX = 10 -- ...capped here
RankedConfig.LEAVER_EXTRA = 10 -- extra points lost for quitting a ranked game
RankedConfig.MIN_RATING = 0

-- Match validity / anti-boosting
RankedConfig.MIN_SECONDS = 60 -- shorter games are "no contest" (no rating change)
RankedConfig.MIN_POINTS = 5 -- total points needed for the game to count
RankedConfig.MAX_SAME_OPPONENT_PER_DAY = 3 -- rated games vs the same player per UTC day

-- Match rewards (on top of rating)
RankedConfig.WIN_CASH = 150
RankedConfig.WIN_XP = 160
RankedConfig.WIN_REP = 20
RankedConfig.LOSS_CASH = 40
RankedConfig.LOSS_XP = 60
RankedConfig.LOSS_REP = 4

---------------------------------------------------------------------------
-- Matchmaking
---------------------------------------------------------------------------
RankedConfig.WINDOW_START = 100 -- rating difference allowed right away
RankedConfig.WINDOW_GROWTH = 25 -- widened by this every WINDOW_STEP seconds queued
RankedConfig.WINDOW_STEP = 5
RankedConfig.WINDOW_MAX = 700
RankedConfig.MATCH_COUNTDOWN = 6 -- seconds on court before tip-off
RankedConfig.FOUND_DELAY = 4 -- seconds between "match found" and the summon
-- Courts tried first (Model names); any other public court comes after.
RankedConfig.PREFERRED_COURTS = { "GrandArena", "NeighborhoodCourt", "OldTownCourt", "BeachCourt" }

---------------------------------------------------------------------------
-- Tiers (floor rating; divisions III -> I inside each tier, Legend has none)
---------------------------------------------------------------------------
RankedConfig.TIERS = {
	{ name = "Bronze", floor = -math.huge, base = 700, color = Color3.fromRGB(205, 127, 50), icon = "🥉" },
	{ name = "Silver", floor = 900, color = Color3.fromRGB(200, 205, 215), icon = "🥈" },
	{ name = "Gold", floor = 1100, color = Color3.fromRGB(255, 200, 60), icon = "🥇" },
	{ name = "Platinum", floor = 1300, color = Color3.fromRGB(110, 225, 210), icon = "💠" },
	{ name = "Diamond", floor = 1500, color = Color3.fromRGB(120, 180, 255), icon = "💎" },
	{ name = "Elite", floor = 1700, color = Color3.fromRGB(200, 110, 255), icon = "🔮" },
	{ name = "Legend", floor = 1900, color = Color3.fromRGB(255, 90, 90), icon = "👑" },
}
RankedConfig.TIER_INDEX = {}
for i, t in RankedConfig.TIERS do
	RankedConfig.TIER_INDEX[t.name] = i
end
RankedConfig.UNRANKED_COLOR = Color3.fromRGB(150, 150, 165)
local DIVISIONS = { "III", "II", "I" }

export type TierInfo = {
	tier: string,
	division: string?, -- "III" | "II" | "I" | nil (Legend)
	label: string, -- "Gold II"
	color: Color3,
	icon: string,
	index: number,
	progress: number, -- 0-1 toward the next division / tier
	nextAt: number?, -- rating of the next step (nil at Legend)
}

function RankedConfig.tierOf(rating: number): TierInfo
	local index = 1
	for i, t in RankedConfig.TIERS do
		if rating >= t.floor then
			index = i
		end
	end
	local t = RankedConfig.TIERS[index]
	local nextTier = RankedConfig.TIERS[index + 1]
	if not nextTier then
		return { tier = t.name, division = nil, label = t.name, color = t.color, icon = t.icon, index = index, progress = 1, nextAt = nil }
	end
	local low = if t.floor == -math.huge then (t.base or 700) else t.floor
	local span = (nextTier.floor - low) / 3
	local step = math.clamp(math.floor((rating - low) / span), 0, 2)
	local stepLow = low + step * span
	local progress = math.clamp((rating - stepLow) / span, 0, 1)
	local division = DIVISIONS[step + 1]
	return {
		tier = t.name,
		division = division,
		label = t.name .. " " .. division,
		color = t.color,
		icon = t.icon,
		index = index,
		progress = progress,
		nextAt = math.floor(stepLow + span + 0.5),
	}
end

function RankedConfig.tierColor(name: string?): Color3
	local i = name and RankedConfig.TIER_INDEX[name]
	return if i then RankedConfig.TIERS[i].color else RankedConfig.UNRANKED_COLOR
end

---------------------------------------------------------------------------
-- Seasons: a fixed schedule from an epoch, so every server agrees.
---------------------------------------------------------------------------
RankedConfig.SEASON_EPOCH = 1790812800 -- 2026-10-01 00:00:00 UTC
RankedConfig.SEASON_WEEKS = 10
RankedConfig.SEASON_LENGTH = RankedConfig.SEASON_WEEKS * 7 * 86400
RankedConfig.SOFT_RESET = 0.5 -- new rating = 1000 + (old - 1000) * this

export type Season = { id: string, number: number, name: string, startsAt: number, endsAt: number }

function RankedConfig.seasonNumber(t: number): number
	return math.max(1, math.floor((t - RankedConfig.SEASON_EPOCH) / RankedConfig.SEASON_LENGTH) + 1)
end

function RankedConfig.seasonByNumber(n: number): Season
	local startsAt = RankedConfig.SEASON_EPOCH + (n - 1) * RankedConfig.SEASON_LENGTH
	return { id = "S" .. n, number = n, name = "Season " .. n, startsAt = startsAt, endsAt = startsAt + RankedConfig.SEASON_LENGTH }
end

function RankedConfig.seasonAt(t: number): Season
	return RankedConfig.seasonByNumber(RankedConfig.seasonNumber(t))
end

function RankedConfig.seasonNumberOfId(id: any): number?
	if type(id) ~= "string" then
		return nil
	end
	local n = tonumber(id:match("^S(%d+)$"))
	return n
end

---------------------------------------------------------------------------
-- Season rewards by final tier (placements must be finished)
---------------------------------------------------------------------------
-- badge = the exclusive season badge (a coloured tag over your head and on your
-- profile) for high ranks. item = a Threads wardrobe item id granted when the
-- shop catalog defines it (see the Ranked report for the ShopsConfig patch).
RankedConfig.REWARDS = {
	Bronze = { cash = 500, xp = 250 },
	Silver = { cash = 1200, xp = 500 },
	Gold = { cash = 2500, xp = 1000 },
	Platinum = { cash = 5000, xp = 2000, badge = true },
	Diamond = { cash = 10000, xp = 4000, badge = true, item = "ranked_diamond_jacket" },
	Elite = { cash = 20000, xp = 7000, badge = true, item = "ranked_elite_jacket" },
	Legend = { cash = 40000, xp = 12000, badge = true, item = "ranked_legend_jacket" },
}

-- "S1 Diamond"
function RankedConfig.seasonTitle(seasonId: string, tier: string): string
	return seasonId .. " " .. tier
end

RankedConfig.HISTORY_LIMIT = 10 -- matches kept for the phone
RankedConfig.SEASON_HISTORY_LIMIT = 20

return RankedConfig
