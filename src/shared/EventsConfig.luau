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
} :: { [string]: Kind }

EventsConfig.ORDER = { "ThreePoint", "City5K", "CarMeet" }
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
