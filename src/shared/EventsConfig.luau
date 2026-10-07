-- CITY GRIND: city events tuning (spec sections 41, 57, 58, 63, 92, 114).
-- Shared by the server (which runs and judges every event) and the client
-- (which draws the Events app, the live HUD and the vote panel).

local EventsConfig = {}

-- Scheduler: a new event every 12-20 minutes of server time, announced
-- city-wide 5 minutes ahead and again when it starts.
EventsConfig.FIRST_EVENT_DELAY = 6 * 60
EventsConfig.MIN_GAP = 12 * 60
EventsConfig.MAX_GAP = 20 * 60
EventsConfig.ANNOUNCE_AHEAD = 5 * 60
EventsConfig.REMINDER_AHEAD = 60
EventsConfig.UPCOMING_COUNT = 3 -- how many future events are scheduled (and listed) at once
EventsConfig.RESULTS_KEPT = 8
EventsConfig.POSTPONE_SECONDS = 120 -- 3-point contest waits this long if the court is busy
EventsConfig.MAX_POSTPONES = 3

export type Reward = { cash: number, xp: number, rep: number }
export type Kind = {
	id: string,
	name: string,
	icon: string,
	color: Color3,
	location: string,
	blurb: string,
	maxPlayers: number,
	duration: number, -- rough minutes shown in the app
	podium: { Reward },
	finisher: Reward,
}

EventsConfig.KINDS = {
	ThreePoint = {
		id = "ThreePoint",
		name = "3-Point Contest",
		icon = "🏀",
		color = Color3.fromRGB(255, 140, 40),
		location = "Neighborhood Court",
		blurb = "60 seconds, 5 racks beyond the arc. The last ball of each rack is the money ball (2 pts).",
		maxPlayers = 8,
		duration = 6,
		podium = {
			{ cash = 250, xp = 200, rep = 10 },
			{ cash = 150, xp = 120, rep = 6 },
			{ cash = 90, xp = 80, rep = 4 },
		},
		finisher = { cash = 40, xp = 40, rep = 1 },
	},
	City5K = {
		id = "City5K",
		name = "City 5K Run",
		icon = "🏃",
		color = Color3.fromRGB(80, 220, 120),
		location = "Main St start arch",
		blurb = "A full lap of the Neighborhood on foot. Hit every checkpoint in order. No vehicles.",
		maxPlayers = 16,
		duration = 7,
		podium = {
			{ cash = 300, xp = 250, rep = 12 },
			{ cash = 180, xp = 150, rep = 8 },
			{ cash = 110, xp = 100, rep = 5 },
		},
		finisher = { cash = 50, xp = 60, rep = 2 },
	},
	CarMeet = {
		id = "CarMeet",
		name = "Car Meet",
		icon = "🚗",
		color = Color3.fromRGB(150, 90, 255),
		location = "Car Meet Lot",
		blurb = "Spawn your ride, park it in a marked bay, then vote Best Car, Best Colour and Best Customization.",
		maxPlayers = 10,
		duration = 5,
		podium = {
			-- per category won
			{ cash = 120, xp = 100, rep = 8 },
		},
		finisher = { cash = 40, xp = 40, rep = 2 },
	},
	DunkContest = {
		id = "DunkContest",
		name = "Dunk Contest",
		icon = "💥",
		color = Color3.fromRGB(255, 70, 70),
		location = "City court",
		blurb = "3 dunk attempts each. Made dunks score on approach speed, hang time, take-off distance and variety.",
		maxPlayers = 8,
		duration = 6,
		podium = {
			{ cash = 260, xp = 210, rep = 10 },
			{ cash = 160, xp = 130, rep = 6 },
			{ cash = 100, xp = 85, rep = 4 },
		},
		finisher = { cash = 40, xp = 40, rep = 1 },
	},
	TreasureHunt = {
		id = "TreasureHunt",
		name = "Treasure Hunt",
		icon = "🗝️",
		color = Color3.fromRGB(255, 205, 60),
		location = "All over the city",
		blurb = "Glowing caches are hidden across the districts. Clues unlock over time. First to touch a cache claims it.",
		maxPlayers = 16,
		duration = 7,
		podium = {
			{ cash = 280, xp = 230, rep = 10 },
			{ cash = 170, xp = 140, rep = 6 },
			{ cash = 100, xp = 90, rep = 4 },
		},
		finisher = { cash = 40, xp = 50, rep = 1 },
	},
	PhotoChallenge = {
		id = "PhotoChallenge",
		name = "Photo Challenge",
		icon = "📸",
		color = Color3.fromRGB(80, 200, 255),
		location = "Anywhere in the city",
		blurb = "A theme drops when it starts. Snap a matching photo with the Camera app, submit it, then everyone votes.",
		maxPlayers = 12,
		duration = 7,
		podium = {
			{ cash = 220, xp = 180, rep = 10 },
			{ cash = 140, xp = 110, rep = 6 },
			{ cash = 90, xp = 75, rep = 4 },
		},
		finisher = { cash = 35, xp = 40, rep = 1 },
	},
	FashionShow = {
		id = "FashionShow",
		name = "Fashion Show",
		icon = "👗",
		color = Color3.fromRGB(255, 110, 200),
		location = "Pop-up runway",
		blurb = "Wear your best fit from your closet, walk the runway when it's your turn, then the crowd votes.",
		maxPlayers = 10,
		duration = 6,
		podium = {
			{ cash = 220, xp = 180, rep = 10 },
			{ cash = 140, xp = 110, rep = 6 },
			{ cash = 90, xp = 75, rep = 4 },
		},
		finisher = { cash = 35, xp = 40, rep = 1 },
	},
	StreetballTournament = {
		id = "StreetballTournament",
		name = "Streetball Tournament",
		icon = "🏆",
		color = Color3.fromRGB(255, 160, 60),
		location = "City court",
		blurb = "Knockout bracket of half-court games (1v1, or 2v2 with a big field). Ones and twos, first to 7.",
		maxPlayers = 8,
		duration = 10,
		podium = {
			{ cash = 320, xp = 260, rep = 14 },
			{ cash = 190, xp = 160, rep = 8 },
			{ cash = 110, xp = 100, rep = 5 },
		},
		finisher = { cash = 45, xp = 50, rep = 2 },
	},
} :: { [string]: Kind }

EventsConfig.ORDER = { "ThreePoint", "City5K", "CarMeet", "DunkContest", "TreasureHunt", "PhotoChallenge", "FashionShow", "StreetballTournament" }

-- Fewest checked-in entrants a kind needs; below this it is cancelled cleanly.
EventsConfig.MIN_ENTRANTS = {
	ThreePoint = 1,
	City5K = 1,
	CarMeet = 2,
	DunkContest = 2,
	TreasureHunt = 1,
	PhotoChallenge = 2,
	FashionShow = 2,
	StreetballTournament = 2,
}

-- Dunk contest: every made dunk is scored from what the server saw.
EventsConfig.DUNK = {
	CHECKIN = 60,
	READY = 3,
	TURN = 40,
	ATTEMPTS = 3,
	BASE = 5, -- a made dunk
	SPEED_FROM = 14, -- studs/s where approach points start
	SPEED_STEP = 3, -- +1 per this many studs/s above SPEED_FROM
	SPEED_MAX = 4,
	AIR_PER_SECOND = 5, -- hang time points per airborne second before the release
	AIR_MAX = 3,
	TAKEOFF_FROM = 3, -- take-off distance from the rim where points start
	TAKEOFF_STEP = 1.2,
	TAKEOFF_MAX = 2,
	NEW_ANGLE = 2, -- first dunk from a new approach (baseline / wing / straight)
	MISS_RETURN = 2.5, -- seconds a missed ball rolls before it's handed back
	START_DIST = 22, -- where each turn starts, from the rim toward half court
}

-- Treasure hunt
EventsConfig.HUNT = {
	CHECKIN = 30,
	TIME_LIMIT = 6 * 60,
	CACHES = 6,
	CLUE_EVERY = 25, -- a new cache's district clue every N seconds
	LANDMARK_AFTER = 50, -- then its landmark hint this long after that
	BEARING_AFTER = 110, -- then a compass bearing + distance
	TOUCH_RADIUS = 6,
	MIN_SPACING = 70,
	-- known open ground used when the districts have no free spot
	FALLBACK = {
		Vector3.new(150, 0, 190),
		Vector3.new(-262, 0, 120),
		Vector3.new(210, 0, -195),
		Vector3.new(-170, 0, 205),
		Vector3.new(-262, 0, -140),
		Vector3.new(60, 0, 205),
	},
}

-- Photo challenge. Themes are checked on the server against the saved
-- snapshot (where the camera was, the time of day, who / what is in frame).
EventsConfig.PHOTO = {
	SHOOT = 4 * 60,
	VOTE = 60,
	DAY_SECONDS = 20 * 60, -- one in-game day (Main's DAY_LENGTH_SECONDS); time themes need enough of their window
	MIN_WINDOW_HOURS = 1.2, -- in-game hours of a time theme's window that must fall inside the shoot
	MAX_PHOTOS_LISTED = 12,
	THEMES = {
		{ id = "sunset", name = "Sunset at the Beach", rule = "Taken at the Beach between 16:30 and 20:00", clockFrom = 16.5, clockTo = 20 },
		{ id = "crew", name = "Crew Pic", rule = "3 or more people in the photo" },
		{ id = "neon", name = "Car with Neon", rule = "A car with its neon underglow on, in frame" },
		{ id = "night", name = "Downtown After Dark", rule = "Taken Downtown at night (19:00-05:30)", clockFrom = 19, clockTo = 5.5 },
		{ id = "hoops", name = "Court Life", rule = "Someone in frame within 40 studs of a basketball court" },
	},
}

-- Fashion show
EventsConfig.FASHION = {
	CHECKIN = 90,
	WALK = 22, -- seconds to reach the end of the runway
	POSE = 3, -- seconds to hold at the end
	VOTE = 50,
	SPECTATOR_RANGE = 90,
	RUNWAY = Vector3.new(10, 1.4, 54),
	-- preferred pop-up spots (first open one wins); the last is a known plaza
	SPOTS = {
		Vector3.new(0, 0, -430),
		Vector3.new(-40, 0, 420),
		Vector3.new(-520, 0, 60),
		Vector3.new(140, 0, 182),
	},
}

-- Streetball tournament: half-court games on a reserved court.
EventsConfig.STREETBALL = {
	CHECKIN = 75,
	TARGET = 7,
	GAME_TIME = 150,
	LOOSE_TURNOVER = 5, -- a ball nobody grabs goes to the other side
	TWO_V_TWO_FROM = 6, -- this many (even) entrants plays 2v2
	BETWEEN = 4, -- seconds between a game ending and the next one starting
}
EventsConfig.FAME_PER_CAR_AWARD = 25

-- 3-point contest
EventsConfig.THREE = {
	CHECKIN = 60, -- seconds to get onto the court once it goes live
	READY = 3, -- seconds between being placed on spot 1 and the clock starting
	TURN = 60,
	BALLS_PER_RACK = 3, -- the last one is the money ball
	SPOT_RADIUS = 22, -- from the rim; the arc is 19, so every spot is a three
	SPOT_ANGLES = { 12, 51, 90, 129, 168 }, -- degrees, corner to corner
	SPOT_REACH = 3.6, -- how close you must stand to a rack to get its next ball
}

-- City 5K. The route follows the sidewalks: east along Main St, up the north
-- cross street, west along Main St, down the south cross street and back.
EventsConfig.RUN = {
	CHECKIN = 60,
	COUNTDOWN = 5,
	TIME_LIMIT = 6 * 60,
	START_RADIUS = 14, -- the start box
	GATE_RADIUS = 13,
	MAX_SPEED = 36, -- studs/s: nobody on foot is faster than a slide (34)
	-- 1 is the start / finish arch; the lap ends back at 1.
	ROUTE = {
		Vector3.new(60, 0, 20), -- south sidewalk, east of the crossing
		Vector3.new(270, 0, 20),
		Vector3.new(270, 0, -20),
		Vector3.new(20, 0, -20),
		Vector3.new(20, 0, -120),
		Vector3.new(20, 0, -210),
		Vector3.new(-20, 0, -210),
		Vector3.new(-20, 0, -20),
		Vector3.new(-20, 0, 110),
		Vector3.new(-20, 0, 210),
		Vector3.new(20, 0, 210),
		Vector3.new(20, 0, 60),
	},
}

-- Car meet lot in the free south strip, west of the cross street.
EventsConfig.MEET = {
	GATHER = 150,
	VOTE = 60,
	LOT_CENTER = Vector3.new(-68, 0, 182),
	LOT_SIZE = Vector3.new(74, 0, 64),
	BAY_SIZE = Vector3.new(11, 0, 20),
	MAX_PARK_SPEED = 3,
	CATEGORIES = { "Best Car", "Best Colour", "Best Customization" },
}

-- Community goal (114): one per hour, counted from real basketball scores.
EventsConfig.GOAL = {
	WINDOW = 60 * 60,
	REWARD = { cash = 100, xp = 75 },
}

-- Discovery billboards (92).
EventsConfig.BOARDS = {
	{ name = "Bus Stop", pos = Vector3.new(-56, 0, 33), facing = -1 },
	{ name = "Subway", pos = Vector3.new(60, 0, -34), facing = 1 },
}

-- "1:05" / "12m" style countdown text.
function EventsConfig.formatIn(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60)
	elseif seconds >= 120 then
		return string.format("%dm", math.ceil(seconds / 60))
	end
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function EventsConfig.formatTime(seconds: number): string
	return string.format("%d:%04.1f", seconds // 60, seconds % 60)
end

function EventsConfig.rewardText(r: Reward): string
	return string.format("$%d · %d XP · +%d rep", r.cash, r.xp, r.rep)
end

return EventsConfig
