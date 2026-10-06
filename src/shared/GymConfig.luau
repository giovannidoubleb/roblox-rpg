-- CITY GRIND: Iron Box Gym tuning (sections 56, 69, 110, 120).
-- Shared by the server (which judges every rep) and the client (which draws
-- the rep meter), so both compute the same marker position and target zone.

local GymConfig = {}

GymConfig.INTERIOR = "Iron Box Gym" -- Player attribute "Interior" while inside
GymConfig.BUILDING = "Iron Box Gym" -- CityBuilder building name

-- Entry (section 69): first visit free, then a day pass or a membership.
GymConfig.DAY_PASS_PRICE = 20
GymConfig.DAY_PASS_SECONDS = 20 * 60 -- real seconds
GymConfig.MEMBERSHIP_PRICE = 400

-- Rep validation (server). A good rep can't come faster than this, and no more
-- than MAX_REPS_PER_MINUTE good reps count in any rolling minute.
GymConfig.MIN_REP_INTERVAL = 0.7
GymConfig.MAX_REPS_PER_MINUTE = 48
GymConfig.MISS_COOLDOWN = 0.35 -- client-side pause after a missed press

-- Fatigue: 0-100, each good rep adds FATIGUE_PER_REP. Above FATIGUE_FREE the
-- gains shrink until MIN_EFFICIENCY at 100. Rest (anywhere, even offline)
-- brings it back to 0 over FATIGUE_RECOVERY_SECONDS.
GymConfig.FATIGUE_PER_REP = 0.7
GymConfig.FATIGUE_FREE = 40
GymConfig.MIN_EFFICIENCY = 0.15
GymConfig.FATIGUE_RECOVERY_SECONDS = 30 * 60

-- Stat XP per good rep before scaling (100 stat XP = +1 stat point).
GymConfig.BASE_STAT_XP = 5
GymConfig.PERFECT_MULT = 1.5
GymConfig.LEVEL_SOFTNESS = 14 -- higher stats train slower: gain / (1 + (stat-1)/14)
GymConfig.PLAYER_XP_GOOD = 1
GymConfig.PLAYER_XP_PERFECT = 2

-- Side-by-side treadmill race (section 56).
GymConfig.RACE_TARGET = 20 -- good reps
GymConfig.RACE_INVITE_SECONDS = 15
GymConfig.RACE_BONUS_REPS = 6 -- winner gets this many perfect reps worth of stat XP
GymConfig.RACE_BONUS_XP = 15

-- Station types. stats = { {statName, weight} } (weight multiplies BASE_STAT_XP).
-- period = seconds for the marker to sweep across and back.
-- good / perfect = half-width of the target zone (meter runs 0..1).
GymConfig.STATIONS = {
	Treadmill = { label = "Treadmill", stats = { { "Stamina", 1 }, { "Speed", 0.8 } }, period = 1.5, good = 0.13, perfect = 0.04, color = Color3.fromRGB(80, 200, 255) },
	Bike = { label = "Exercise Bike", stats = { { "Stamina", 1.1 } }, period = 1.6, good = 0.14, perfect = 0.04, color = Color3.fromRGB(110, 230, 160) },
	Bench = { label = "Bench Press", stats = { { "Strength", 1.1 } }, period = 1.8, good = 0.11, perfect = 0.035, color = Color3.fromRGB(255, 110, 80) },
	Dumbbells = { label = "Dumbbells", stats = { { "Strength", 0.9 } }, period = 1.4, good = 0.13, perfect = 0.04, color = Color3.fromRGB(255, 160, 70) },
	Squat = { label = "Squat Rack", stats = { { "Vertical", 1 }, { "Strength", 0.6 } }, period = 1.9, good = 0.11, perfect = 0.035, color = Color3.fromRGB(190, 120, 255) },
	PullUp = { label = "Pull-up Bar", stats = { { "Strength", 1.2 } }, period = 2.0, good = 0.10, perfect = 0.03, color = Color3.fromRGB(255, 90, 140) },
	Cable = { label = "Cable Machine", stats = { { "Strength", 0.7 }, { "Defense", 0.8 } }, period = 1.7, good = 0.12, perfect = 0.035, color = Color3.fromRGB(90, 170, 255) },
	Abs = { label = "Ab Mat", stats = { { "Stamina", 0.6 }, { "Finishing", 0.8 } }, period = 1.5, good = 0.13, perfect = 0.04, color = Color3.fromRGB(255, 210, 70) },
}
GymConfig.ORDER = { "Treadmill", "Bike", "Bench", "Dumbbells", "Squat", "PullUp", "Cable", "Abs" }

-- Daily challenges rotate by UTC day.
GymConfig.CHALLENGES = {
	{ station = "Bench", reps = 50, cash = 120, xp = 150, text = "Do 50 bench press reps" },
	{ station = "Treadmill", reps = 80, cash = 110, xp = 140, text = "Log 80 good strides on a treadmill" },
	{ station = "Squat", reps = 40, cash = 130, xp = 160, text = "Hit 40 squats" },
	{ station = "PullUp", reps = 30, cash = 140, xp = 170, text = "Do 30 pull-ups" },
	{ station = "Dumbbells", reps = 60, cash = 110, xp = 140, text = "Curl 60 dumbbell reps" },
	{ station = "Bike", reps = 70, cash = 100, xp = 130, text = "Pedal 70 good reps on the bike" },
	{ station = "Cable", reps = 45, cash = 120, xp = 150, text = "Do 45 cable flys" },
	{ station = "Abs", reps = 60, cash = 100, xp = 130, text = "Crunch out 60 ab reps" },
}

function GymConfig.day(unixTime: number): number
	return math.floor(unixTime / 86400)
end

function GymConfig.challengeFor(day: number)
	return GymConfig.CHALLENGES[day % #GymConfig.CHALLENGES + 1]
end

-- Marker position 0..1 (a triangle wave) at server time `t`.
function GymConfig.meterPos(t: number, start: number, period: number): number
	local f = ((t - start) / period) % 1
	return if f < 0.5 then f * 2 else 2 - f * 2
end

-- Centre of the target zone for the n-th good rep of a set.
function GymConfig.zoneCenter(seed: number, n: number): number
	return Random.new(seed + n * 7919):NextNumber(0.22, 0.78)
end

-- Judges a press: "perfect", "good" or "miss".
function GymConfig.judge(kind: string, t: number, start: number, seed: number, goodReps: number): string
	local def = GymConfig.STATIONS[kind]
	local d = math.abs(GymConfig.meterPos(t, start, def.period) - GymConfig.zoneCenter(seed, goodReps))
	if d <= def.perfect then
		return "perfect"
	elseif d <= def.good then
		return "good"
	end
	return "miss"
end

-- Fatigue after resting since `at` (unix seconds).
function GymConfig.currentFatigue(fatigue: number, at: number, now: number): number
	local rested = math.max(0, now - at)
	return math.max(0, fatigue - rested * 100 / GymConfig.FATIGUE_RECOVERY_SECONDS)
end

-- Fraction of normal gains at this fatigue.
function GymConfig.efficiency(fatigue: number): number
	if fatigue <= GymConfig.FATIGUE_FREE then
		return 1
	end
	local t = math.clamp((fatigue - GymConfig.FATIGUE_FREE) / (100 - GymConfig.FATIGUE_FREE), 0, 1)
	return 1 - (1 - GymConfig.MIN_EFFICIENCY) * t
end

-- Stat XP for one rep, rounded to 0.1 (at least 0.1).
function GymConfig.statGain(statValue: number, weight: number, perfect: boolean, efficiency: number): number
	local amount = GymConfig.BASE_STAT_XP * weight * (if perfect then GymConfig.PERFECT_MULT else 1) * efficiency
	amount /= 1 + (math.max(1, statValue) - 1) / GymConfig.LEVEL_SOFTNESS
	return math.max(0.1, math.floor(amount * 10 + 0.5) / 10)
end

return GymConfig
