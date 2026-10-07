-- CITY GRIND: the story (spec 83, 109, 110). Eight chapters of real missions
-- that walk a new player through the city's systems in first-hour order.
--
-- A mission is done when the server-side lifetime metric `metric` reaches
-- `goal` (see server/Quests.luau metric()). `alt` is a second way to finish
-- missions that normally need other players, so a solo player is never stuck.
-- `place` is a GPS target the server resolves at runtime: a City.MapPoints
-- name, "court" (nearest court) or a district id. `needs` = "districts" skips
-- the mission when the districts / subway aren't built in this place.

local StoryConfig = {}

export type Mission = {
	text: string,
	metric: string,
	goal: number,
	alt: { metric: string, goal: number, text: string }?,
	place: string?,
	needs: string?,
	hint: string?,
}

export type Chapter = {
	name: string,
	intro: string, -- Coach Ray's text when the chapter starts
	outro: string, -- Coach Ray's text when it's done
	missions: { Mission },
	cash: number,
	xp: number,
	rep: number,
	title: string?,
}

StoryConfig.COACH = "Coach Ray"
StoryConfig.FIRST_MOVE = "MAKE YOUR FIRST MOVE"

-- Per-mission reward = base * chapter number.
StoryConfig.MISSION_CASH = 75
StoryConfig.MISSION_XP = 60

StoryConfig.CHAPTERS = {
	{
		name = "The New Kid",
		intro = "Alright, rookie. Step one: pull out your phone (press P or tap Phone). Everything in this city runs through it.",
		outro = "Not bad for day one. You've got a roof, a jumper and a drink in your hand. Now let's make some noise.",
		cash = 300, xp = 200, rep = 10,
		missions = {
			{ text = "Open your phone", metric = "phone", goal = 1, hint = "Press P, DPad-Up, or tap the Phone button." },
			{ text = "Enter your apartment at Maple Court", metric = "apartment", goal = 1, place = "Starter Apartments" },
			{ text = "Grab a ball at a court and make a shot", metric = "shots", goal = 1, place = "court" },
			{ text = "Buy a drink at Corner Mart", metric = "drinks", goal = 1, place = "Corner Mart", hint = "Inside the Mart or at the vending machine out front." },
		},
	},
	{
		name = "Make Your Name",
		intro = "Respect is earned with sweat and a paycheck. Hit Iron Box Gym, then pick up a shift at the Job Center.",
		outro = "Body's working, wallet's working. People are starting to notice you on the court.",
		cash = 600, xp = 400, rep = 20,
		missions = {
			{ text = "Train at Iron Box Gym (10 good reps)", metric = "reps", goal = 10, place = "Iron Box Gym" },
			{ text = "Finish your first job shift", metric = "jobs", goal = 1, place = "Job Center" },
			{ text = "Make your first purchase at Threads Clothing", metric = "threads", goal = 1, place = "Threads Clothing" },
			{ text = "Win a pickup game", metric = "wins", goal = 1, place = "court", alt = { metric = "shots", goal = 25, text = "or make 25 shots if the courts are empty" } },
		},
	},
	{
		name = "Earn Respect",
		intro = "Time to get around. Get yourself some wheels, see Downtown, and let the city see you.",
		outro = "You're Known now. That's the first rung. Don't get comfortable.",
		cash = 1200, xp = 800, rep = 30,
		missions = {
			{ text = "Buy a vehicle at Budget Wheels", metric = "vehicles", goal = 1, place = "Budget Wheels" },
			{ text = "Ride the subway to Downtown", metric = "subwayDowntown", goal = 1, place = "Subway Station", needs = "districts" },
			{ text = "Take a photo and post it on CityGram", metric = "posts", goal = 1, hint = "Snap one with the Camera app, then post it from CityGram." },
			{ text = "Reach 100 reputation", metric = "rep", goal = 100 },
		},
	},
	{
		name = "The First Tournament",
		intro = "The city runs events all day: contests, races, car meets. Sign up, compete, and get on that podium.",
		outro = "Podium finish. Folks are saying your name at the courts now.",
		cash = 2500, xp = 1500, rep = 50,
		missions = {
			{ text = "Take part in a city event", metric = "events", goal = 1, hint = "Check the Events app for what's next." },
			{ text = "Score 50 points in pickup games", metric = "points", goal = 50, place = "court", alt = { metric = "shots", goal = 100, text = "or make 100 shots in total" } },
			{ text = "Reach Level 10", metric = "level", goal = 10 },
			{ text = "Finish top 3 in a city event", metric = "podiums", goal = 1, alt = { metric = "events", goal = 3, text = "or take part in 3 events" } },
		},
	},
	{
		name = "Moving Up",
		intro = "That Studio served you well. Time to move up: a bigger place, a better job title, a fatter bank account.",
		outro = "New address, new level. You're not the new kid anymore.",
		cash = 6000, xp = 3000, rep = 80,
		missions = {
			{ text = "Upgrade your home at Maple Realty", metric = "homeTier", goal = 2, place = "Maple Realty" },
			{ text = "Reach job level 5 in any job", metric = "jobLevel", goal = 5, place = "Job Center" },
			{ text = "Earn $25,000 in total", metric = "earned", goal = 25000 },
			{ text = "Reach Level 15", metric = "level", goal = 15 },
		},
	},
	{
		name = "City Famous",
		intro = "Skills pay bills, but fame opens doors. Post, film, run with a crew. Make the city talk.",
		outro = "Local Star. Your face is on phones all over town.",
		cash = 15000, xp = 6000, rep = 120,
		missions = {
			{ text = "Post 5 photos on CityGram", metric = "posts", goal = 5 },
			{ text = "Post a highlight on CityTok", metric = "tokPosts", goal = 1, hint = "Make a play, then POST it from the highlight popup." },
			{ text = "Join or start a crew", metric = "crew", goal = 1, hint = "Crew app on your phone." },
			{ text = "Reach Local Star (1,000 reputation)", metric = "rep", goal = 1000 },
		},
	},
	{
		name = "The Big League",
		intro = "This is where most people stop. Luxury living, big money, a real winning record. Keep climbing.",
		outro = "Celebrity status. One chapter left. The top is in sight.",
		cash = 40000, xp = 15000, rep = 200,
		missions = {
			{ text = "Reach Level 35", metric = "level", goal = 35 },
			{ text = "Win 25 pickup games", metric = "wins", goal = 25, place = "court", alt = { metric = "points", goal = 750, text = "or score 750 points in games" } },
			{ text = "Own a Luxury Apartment", metric = "homeTier", goal = 3, place = "Maple Realty" },
			{ text = "Earn $250,000 in total", metric = "earned", goal = 250000 },
			{ text = "Reach Celebrity (5,000 reputation)", metric = "rep", goal = 5000 },
		},
	},
	{
		name = "Rise to the Top",
		intro = "Last chapter, kid. Legends aren't born, they grind. Show this city who runs it.",
		outro = "You did it. From nobody to the top of the city. I always knew you had it. Now go defend it.",
		cash = 150000, xp = 40000, rep = 500, title = "Top of the City",
		missions = {
			{ text = "Reach Level 75", metric = "level", goal = 75 },
			{ text = "Reach the Legend rank (10,000 reputation)", metric = "rep", goal = 10000 },
			{ text = "Win 3 city event podiums", metric = "podiums", goal = 3, alt = { metric = "events", goal = 25, text = "or take part in 25 events" } },
			{ text = "Earn $1,000,000 in total", metric = "earned", goal = 1000000 },
		},
	},
} :: { Chapter }

-- Cinematic captions (109).
StoryConfig.CINEMATIC_LINES = { "Every city has a hierarchy.", "Nobody starts at the top." }

return StoryConfig
